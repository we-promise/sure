class SimplefinItem < ApplicationRecord
  include Syncable, Provided

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Virtual attribute for the setup token form field
  attr_accessor :setup_token

  if Rails.application.credentials.active_record_encryption.present?
    encrypts :access_url, deterministic: true
  end

  # Helper to detect if ActiveRecord Encryption is configured for this app
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  validates :name, :access_url, presence: true

  before_destroy :remove_simplefin_item

  belongs_to :family
  has_one_attached :logo

  has_many :simplefin_accounts, dependent: :destroy
  has_many :legacy_accounts, through: :simplefin_accounts, source: :account

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  # Get accounts from both new and legacy systems
  def accounts
    # Preload associations to avoid N+1 queries
    simplefin_accounts
      .includes(:account, account_provider: :account)
      .map(&:current_account)
      .compact
      .uniq
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_simplefin_data(sync: nil)
    SimplefinItem::Importer.new(self, simplefin_provider: simplefin_provider, sync: sync).import
  end

  def process_accounts
    simplefin_accounts.joins(:account).each do |simplefin_account|
      SimplefinAccount::Processor.new(simplefin_account).process
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.each do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end

  def upsert_simplefin_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot,
    )

    # Do not populate item-level institution fields from account data.
    # Institution metadata belongs to each simplefin_account (in org_data).

    save!
  end

  def upsert_institution_data!(org_data)
    org = org_data.to_h.with_indifferent_access
    url = org[:url] || org[:"sfin-url"]
    domain = org[:domain]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid SimpleFin institution URL: #{url.inspect}")
      end
    end

    assign_attributes(
      institution_id: org[:id],
      institution_name: org[:name],
      institution_domain: domain,
      institution_url: url,
      raw_institution_payload: org_data
    )
  end


  def has_completed_initial_setup?
    # Setup is complete if we have any linked accounts
    accounts.any?
  end

  def sync_status_summary
    latest = latest_sync
    return nil unless latest

    # If sync has statistics, use them
    if latest.sync_stats.present?
      stats = latest.sync_stats
      total = stats["total_accounts"] || 0
      linked = stats["linked_accounts"] || 0
      unlinked = stats["unlinked_accounts"] || 0

      if total == 0
        "No accounts found"
      elsif unlinked == 0
        "#{linked} #{'account'.pluralize(linked)} synced"
      else
        "#{linked} synced, #{unlinked} need setup"
      end
    else
      # Fallback to current account counts
      total_accounts = simplefin_accounts.count
      linked_count = accounts.count
      unlinked_count = total_accounts - linked_count

      if total_accounts == 0
        "No accounts found"
      elsif unlinked_count == 0
        "#{linked_count} #{'account'.pluralize(linked_count)} synced"
      else
        "#{linked_count} synced, #{unlinked_count} need setup"
      end
    end
  end

  def institution_display_name
    # Try to get institution name from stored metadata
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    # Get unique institutions from all accounts
    simplefin_accounts.includes(:account)
                     .where.not(org_data: nil)
                     .map { |acc| acc.org_data }
                     .uniq { |org| org["domain"] || org["name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      "No institutions connected"
    when 1
      institutions.first["name"] || institutions.first["domain"] || "1 institution"
    else
      "#{institutions.count} institutions"
    end
  end

  # Collapse duplicate SimpleFin accounts for the same upstream account_id within this item.
  # Keeps one record per upstream account_id (prefer the one linked to an Account; else newest),
  # migrates provider links and legacy FKs to the keeper, and deletes extras.
  def dedup_simplefin_accounts!
    dupes = simplefin_accounts.group_by(&:account_id).select { |k, v| k.present? && v.size > 1 }
    return { processed: 0 } if dupes.empty?

    merged_accounts = 0
    moved_entries = 0
    moved_holdings = 0
    legacy_repointed = 0
    removed_providers = 0
    deleted_sfas = 0

    SimplefinItem.transaction do
      dupes.each_value do |list|
        keeper = list.find { |s| s.current_account.present? } || list.max_by(&:updated_at)
        (list - [keeper]).each do |dupe|
          keeper_acct = keeper.current_account
          dupe_acct = dupe.current_account

          # If both SFAs have linked accounts, merge the duplicate account into the keeper account
          if keeper_acct && dupe_acct && keeper_acct.id != dupe_acct.id
            # Move entries with duplicate guard on (external_id, source)
            dupe_acct.entries.find_each do |e|
              if e.external_id.present? && e.source.present? && keeper_acct.entries.exists?(external_id: e.external_id, source: e.source)
                e.destroy!
              else
                e.update_columns(account_id: keeper_acct.id, updated_at: Time.current)
                moved_entries += 1
              end
            end
            # Move holdings with duplicate guard (security,date,currency)
            dupe_acct.holdings.find_each do |h|
              if keeper_acct.holdings.exists?(security_id: h.security_id, date: h.date, currency: h.currency)
                h.destroy!
              else
                h.update_columns(account_id: keeper_acct.id, updated_at: Time.current)
                moved_holdings += 1
              end
            end
            # Remove provider link(s) from the duplicate account
            AccountProvider.where(account_id: dupe_acct.id, provider_type: "SimplefinAccount").delete_all
            # Destroy the duplicate account
            dupe_acct.destroy!
            merged_accounts += 1
          end

          # Repoint legacy FK accounts that still reference the duplicate SFA
          legacy_accounts = Account.where(simplefin_account_id: dupe.id)
          unless legacy_accounts.empty?
            legacy_accounts.update_all(simplefin_account_id: keeper.id, updated_at: Time.current)
            legacy_repointed += legacy_accounts.size
          end

          # Remove any AccountProvider rows pointing at the duplicate SFA (do not move provider_id to avoid unique constraint)
          removed_providers += AccountProvider.where(provider_type: "SimplefinAccount", provider_id: dupe.id).delete_all

          # Finally delete the duplicate SFA
          dupe.destroy!
          deleted_sfas += 1
        end
      end
    end

    { merged_accounts: merged_accounts, moved_entries: moved_entries, moved_holdings: moved_holdings, legacy_repointed: legacy_repointed, removed_providers: removed_providers, deleted_simplefin_accounts: deleted_sfas }
  end

  # Merge duplicate provider-linked Accounts that point to the same SimpleFin account (via AccountProvider).
  # Keeps the account with more entries (or newest), moves entries/holdings from duplicates, and deletes them.
  def merge_duplicate_provider_accounts!
    providers = AccountProvider.where(provider_type: "SimplefinAccount", provider_id: simplefin_accounts.select(:id))
    groups = providers.group_by(&:provider_id).select { |_, list| list.size > 1 }
    return { merged_accounts: 0, moved_entries: 0, moved_holdings: 0, deleted_accounts: 0 } if groups.empty?

    merged = 0
    moved_e = 0
    moved_h = 0
    deleted = 0

    SimplefinItem.transaction do
      groups.each_value do |links|
        accounts = Account.where(id: links.map(&:account_id))
        # Choose keeper by most entries, else newest by updated_at
        keeper = accounts.max_by { |a| [a.entries.count, a.updated_at.to_i] }
        (accounts - [keeper]).each do |dupe|
          # Move entries (avoid duplicates by external_id+source)
          dupe.entries.find_each do |e|
            if e.external_id.present? && e.source.present? && keeper.entries.exists?(external_id: e.external_id, source: e.source)
              e.destroy!
            else
              e.update_columns(account_id: keeper.id, updated_at: Time.current)
              moved_e += 1
            end
          end
          # Move holdings (avoid duplicates by security/date/currency)
          dupe.holdings.find_each do |h|
            if keeper.holdings.exists?(security_id: h.security_id, date: h.date, currency: h.currency)
              h.destroy!
            else
              h.update_columns(account_id: keeper.id, updated_at: Time.current)
              moved_h += 1
            end
          end
          # Remove the duplicate account and its provider links
          AccountProvider.where(account_id: dupe.id, provider_type: "SimplefinAccount").delete_all
          dupe.destroy!
          deleted += 1
        end
        merged += 1
      end
    end

    { merged_accounts: merged, moved_entries: moved_e, moved_holdings: moved_h, deleted_accounts: deleted }
  end

  # Detect a recent rate-limited sync and return a friendly message, else nil
  def rate_limited_message
    latest = latest_sync
    return nil unless latest

    # Some Sync records may not have a status_text column; guard with respond_to?
    parts = []
    parts << latest.error if latest.respond_to?(:error)
    parts << latest.status_text if latest.respond_to?(:status_text)
    msg = parts.compact.join(" — ")
    return nil if msg.blank?

    down = msg.downcase
    if down.include?("make fewer requests") || down.include?("only refreshed once every 24 hours") || down.include?("rate limit")
      "You've hit SimpleFin's daily refresh limit. Please try again after the bridge refreshes (up to 24 hours)."
    else
      nil
    end
  end

  private
    def remove_simplefin_item
      # SimpleFin doesn't require server-side cleanup like Plaid
      # The access URL just becomes inactive
    end
end
