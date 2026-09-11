class SimplefinItem < ApplicationRecord
  include Syncable, Provided, Encryptable
  include SimplefinItem::Unlinking

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Virtual attribute for the setup token form field
  attr_accessor :setup_token

  # Transient, in-memory only. Set by SimplefinItem::Importer#perform_account_discovery
  # to the set of account_ids returned by the current sync's unbounded discovery call.
  # Used by #repair_stale_linkages to verify a "stale" linked account is actually absent
  # upstream, rather than trusting a name match alone. Never persisted.
  attr_accessor :upstream_account_ids

  # Encrypt sensitive credentials and raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :access_url, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  validates :name, presence: true
  validates :access_url, presence: true, on: :create

  before_destroy :remove_simplefin_item

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :simplefin_accounts, dependent: :destroy
  has_many :legacy_accounts, through: :simplefin_accounts, source: :account

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  # Get accounts from both new and legacy systems
  def accounts
    @accounts ||= simplefin_accounts
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

  # Update the access_url by claiming a new setup token.
  # This is used when reconnecting an existing SimpleFIN connection.
  # Unlike create_simplefin_item!, this updates in-place, preserving all account linkages.
  def update_access_url!(setup_token:)
    new_access_url = simplefin_provider.claim_access_url(setup_token)

    update!(
      access_url: new_access_url,
      status: :good
    )

    self
  end

  def process_accounts
    # Process accounts linked via BOTH legacy FK and AccountProvider
    # Use direct query to ensure fresh data from DB, bypassing any association cache
    all_accounts = SimplefinAccount.where(simplefin_item_id: id).includes(:account, :linked_account, account_provider: :account).to_a

    Rails.logger.info "=" * 60
    Rails.logger.info "SimplefinItem#process_accounts START - Item #{id} (#{name})"
    Rails.logger.info "  Total SimplefinAccounts: #{all_accounts.count}"

    # Log all accounts for debugging
    all_accounts.each do |sfa|
      acct = sfa.current_account
      Rails.logger.info "  - SimplefinAccount id=#{sfa.id} sf_account_id=#{sfa.account_id} name='#{sfa.name}'"
      Rails.logger.info "    linked_account: #{sfa.linked_account&.id || 'nil'}, account: #{sfa.account&.id || 'nil'}, current_account: #{acct&.id || 'nil'}"
      Rails.logger.info "    raw_transactions_payload count: #{sfa.raw_transactions_payload.to_a.count}"
    end

    # First, try to repair stale linkages (old SimplefinAccount linked but new one has data)
    repair_stale_linkages(all_accounts)

    # Re-fetch after repairs - use direct query for fresh data
    all_accounts = SimplefinAccount.where(simplefin_item_id: id).includes(:account, :linked_account, account_provider: :account).to_a

    linked = all_accounts.select { |sfa| sfa.current_account.present? }
    unlinked = all_accounts.reject { |sfa| sfa.current_account.present? }

    Rails.logger.info "SimplefinItem#process_accounts - After repair: #{linked.count} linked, #{unlinked.count} unlinked"

    # Log unlinked accounts with transactions for debugging
    unlinked_with_txns = unlinked.select { |sfa| sfa.raw_transactions_payload.to_a.any? }
    if unlinked_with_txns.any?
      Rails.logger.warn "SimplefinItem#process_accounts - #{unlinked_with_txns.count} UNLINKED account(s) have transactions that won't be processed:"
      unlinked_with_txns.each do |sfa|
        Rails.logger.warn "  - SimplefinAccount id=#{sfa.id} name='#{sfa.name}' sf_account_id=#{sfa.account_id} txn_count=#{sfa.raw_transactions_payload.to_a.count}"
      end
    end

    all_skipped_entries = []

    linked.each do |simplefin_account|
      acct = simplefin_account.current_account
      Rails.logger.info "SimplefinItem#process_accounts - Processing: SimplefinAccount id=#{simplefin_account.id} name='#{simplefin_account.name}' -> Account id=#{acct.id} name='#{acct.name}' type=#{acct.accountable_type}"
      processor = SimplefinAccount::Processor.new(simplefin_account)
      processor.process
      all_skipped_entries.concat(processor.skipped_entries)
    end

    Rails.logger.info "SimplefinItem#process_accounts END - #{all_skipped_entries.size} entries skipped (protected)"
    Rails.logger.info "=" * 60

    all_skipped_entries
  end

  # Repairs stale linkages when user re-adds institution in SimpleFIN.
  # When a user deletes and re-adds an institution in SimpleFIN, new account IDs are generated.
  # This causes old SimplefinAccounts to remain "linked" but stale (no new data),
  # while new SimplefinAccounts have data but are unlinked.
  # This method detects such cases and transfers the linkage from old to new.
  def repair_stale_linkages(all_accounts)
    linked = all_accounts.select { |sfa| sfa.current_account.present? }
    unlinked = all_accounts.reject { |sfa| sfa.current_account.present? }

    Rails.logger.info "SimplefinItem#repair_stale_linkages - #{linked.count} linked, #{unlinked.count} unlinked SimplefinAccounts"

    # Find unlinked accounts that have transactions
    unlinked_with_data = unlinked.select { |sfa| sfa.raw_transactions_payload.to_a.any? }

    if unlinked_with_data.any?
      Rails.logger.info "SimplefinItem#repair_stale_linkages - Found #{unlinked_with_data.count} unlinked SimplefinAccount(s) with transactions:"
      unlinked_with_data.each do |sfa|
        Rails.logger.info "  - id=#{sfa.id} name='#{sfa.name}' account_id=#{sfa.account_id} txn_count=#{sfa.raw_transactions_payload.to_a.count}"
      end
    end

    return if unlinked_with_data.empty?

    # Without a current picture of what the provider actually returned this sync, a
    # name match alone cannot distinguish a genuinely stale account (re-added institution,
    # new account_id) from two distinct upstream accounts that merely share a display name.
    # Refuse to act rather than risk hijacking a live linkage. See GH issue #2852.
    if upstream_account_ids.nil?
      Rails.logger.warn "SimplefinItem#repair_stale_linkages - upstream_account_ids unavailable, skipping repair to avoid hijacking a live linkage"
      DebugLogEntry.capture(
        category: "provider_sync_warning",
        level: "warn",
        message: "Skipped stale-linkage repair: upstream_account_ids unavailable",
        source: self.class.name,
        provider_key: "simplefin",
        family: family,
        metadata: { simplefin_item_id: id, unlinked_with_data_count: unlinked_with_data.count }
      )
      return
    end

    # For each unlinked account with data, try to find a matching linked account
    unlinked_with_data.each do |new_sfa|
      # Find linked SimplefinAccount with same name (case-insensitive) that is ALSO
      # actually absent from the current upstream response. A name match alone is not
      # enough: two distinct upstream accounts can legitimately share a display name.
      stale_matches = linked.select do |old_sfa|
        old_sfa.name.to_s.downcase.strip == new_sfa.name.to_s.downcase.strip &&
          old_sfa.account_id.present? &&
          upstream_account_ids.exclude?(old_sfa.account_id.to_s)
      end

      if stale_matches.size > 1
        Rails.logger.warn "SimplefinItem#repair_stale_linkages - Multiple stale linked accounts match '#{new_sfa.name}': #{stale_matches.map(&:id).join(', ')}. Ambiguous, skipping repair."
        next
      end

      stale_match = stale_matches.first
      next unless stale_match

      account = stale_match.current_account
      Rails.logger.info "SimplefinItem#repair_stale_linkages - Found matching accounts:"
      Rails.logger.info "  - OLD: SimplefinAccount id=#{stale_match.id} account_id=#{stale_match.account_id} txn_count=#{stale_match.raw_transactions_payload.to_a.count}"
      Rails.logger.info "  - NEW: SimplefinAccount id=#{new_sfa.id} account_id=#{new_sfa.account_id} txn_count=#{new_sfa.raw_transactions_payload.to_a.count}"
      Rails.logger.info "  - Linked to Account: '#{account.name}' (id=#{account.id})"

      # Transfer the linkage from old to new
      begin
        # Merge transactions from old to new before transferring
        old_transactions = stale_match.raw_transactions_payload.to_a
        new_transactions = new_sfa.raw_transactions_payload.to_a
        if old_transactions.any?
          Rails.logger.info "SimplefinItem#repair_stale_linkages - Merging #{old_transactions.count} transactions from old SimplefinAccount"
          merged = merge_transactions(old_transactions, new_transactions)
          new_sfa.update!(raw_transactions_payload: merged)
        end

        # Check if linked via legacy FK (use to_s for UUID comparison safety)
        if account.simplefin_account_id.to_s == stale_match.id.to_s
          account.simplefin_account_id = new_sfa.id
          account.save!
        end

        # Check if linked via AccountProvider
        if stale_match.account_provider.present?
          Rails.logger.info "SimplefinItem#repair_stale_linkages - Transferring AccountProvider linkage from SimplefinAccount #{stale_match.id} to #{new_sfa.id}"
          stale_match.account_provider.update!(provider: new_sfa)
        end

        # If the new one doesn't have an AccountProvider yet, create one
        new_sfa.ensure_account_provider!

        Rails.logger.info "SimplefinItem#repair_stale_linkages - Successfully transferred linkage for Account '#{account.name}' to SimplefinAccount id=#{new_sfa.id}"

        # Clear transactions from stale SimplefinAccount and leave it orphaned
        # We don't destroy it because has_one :account, dependent: :nullify would nullify the FK we just set
        # IMPORTANT: Use update_all to bypass AR associations - stale_match.update! would
        # trigger autosave on the preloaded account association, reverting the FK we just set!
        SimplefinAccount.where(id: stale_match.id).update_all(raw_transactions_payload: [], raw_holdings_payload: [])
        Rails.logger.info "SimplefinItem#repair_stale_linkages - Cleared data from stale SimplefinAccount id=#{stale_match.id} (leaving orphaned)"
      rescue => e
        Rails.logger.error "SimplefinItem#repair_stale_linkages - Failed to transfer linkage: #{e.class} - #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n") if e.backtrace
      end
    end
  end

  # Merge two arrays of transactions, deduplicating by ID.
  # Fallback: uses composite key [posted, amount, description] when ID/fitid missing.
  #
  # Known edge cases with composite key fallback:
  # 1. False positives: Two distinct transactions with identical posted/amount/description
  #    will be incorrectly merged (rare but possible).
  # 2. Type inconsistency: If posted varies in type (String vs Integer), keys won't match.
  # 3. Description variations: Minor differences (whitespace, case) prevent matching.
  #
  # SimpleFIN typically provides transaction IDs, so this fallback is rarely needed.
  def merge_transactions(old_txns, new_txns)
    by_id = {}

    # Add old transactions first
    old_txns.each do |tx|
      t = tx.with_indifferent_access
      key = t[:id] || t[:fitid] || [ t[:posted], t[:amount], t[:description] ]
      by_id[key] = tx
    end

    # Add new transactions (overwrite old with same ID)
    new_txns.each do |tx|
      t = tx.with_indifferent_access
      key = t[:id] || t[:fitid] || [ t[:posted], t[:amount], t[:description] ]
      by_id[key] = tx
    end

    by_id.values
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
    stats = parse_sync_stats(latest.sync_stats)
    if stats.present?
      total = stats["total_accounts"] || 0
      linked = stats["linked_accounts"] || 0
      unlinked = stats["unlinked_accounts"] || 0
    else
      # Fallback to current account counts
      total = simplefin_accounts.count
      linked = accounts.count
      unlinked = total - linked
    end

    if total == 0
      I18n.t("simplefin_items.sync_status.no_accounts")
    elsif unlinked == 0
      I18n.t("simplefin_items.sync_status.synced", count: linked)
    else
      I18n.t("simplefin_items.sync_status.partial_setup", count: unlinked, linked: linked, unlinked: unlinked)
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
      I18n.t("simplefin_items.institution_summary.none")
    when 1
      institutions.first["name"] || institutions.first["domain"] || I18n.t("simplefin_items.institution_summary.count", count: 1)
    else
      I18n.t("simplefin_items.institution_summary.count", count: institutions.count)
    end
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
      I18n.t("simplefin_items.rate_limited.daily_refresh")
    else
      nil
    end
  end

  # Detect if sync data appears stale (no new transactions for extended period)
  # Returns a hash with :stale (boolean) and :message (string) if stale
  def stale_sync_status
    return { stale: false } unless last_synced_at.present?

    # Check if last sync was more than 3 days ago
    days_since_sync = (Date.current - last_synced_at.to_date).to_i
    if days_since_sync > 3
      return {
        stale: true,
        days_since_sync: days_since_sync,
        message: I18n.t("simplefin_items.stale_sync.last_successful", count: days_since_sync)
      }
    end

    # Check if linked accounts have recent transactions
    linked_accounts = accounts
    return { stale: false } if linked_accounts.empty?

    # Find the most recent transaction date across all linked accounts
    latest_transaction_date = Entry.where(account_id: linked_accounts.map(&:id))
                                   .where(entryable_type: "Transaction")
                                   .maximum(:date)

    if latest_transaction_date.present?
      days_since_transaction = (Date.current - latest_transaction_date).to_i
      if days_since_transaction > 14
        return {
          stale: true,
          days_since_transaction: days_since_transaction,
          message: I18n.t("simplefin_items.stale_sync.no_transactions", count: days_since_transaction)
        }
      end
    end

    { stale: false }
  end

  # Check if the SimpleFin connection needs user attention
  def needs_attention?
    setup_token_update_required? || stale_sync_status[:stale] || pending_account_setup?
  end

  # Get a summary of issues requiring attention
  def attention_summary
    issues = []
    issues << "Connection needs update" if setup_token_update_required?
    issues << stale_sync_status[:message] if stale_sync_status[:stale]
    issues << "Accounts need setup" if pending_account_setup?
    issues
  end

  # A SimpleFIN setup token is only needed when the bridge access URL appears
  # unusable. If the latest sync returned accounts, the access URL still works;
  # any auth warning in that response belongs to an individual institution.
  def setup_token_update_required?(latest_sync: nil)
    return false unless requires_update?

    latest = latest_sync || syncs.ordered.first
    return true unless latest
    return false if latest.in_progress?

    stats = parse_sync_stats(latest.sync_stats).to_h.stringify_keys
    stats["total_accounts"].to_i.zero?
  end

  def effective_status(latest_sync: nil)
    setup_token_update_required?(latest_sync: latest_sync) ? status : "good"
  end

  # Get reconciled duplicates count from the last sync
  # Returns { count: N, message: "..." } or { count: 0 } if none
  def last_sync_reconciled_status
    latest_sync = syncs.ordered.first
    return { count: 0 } unless latest_sync

    stats = parse_sync_stats(latest_sync.sync_stats)
    count = stats&.dig("pending_reconciled").to_i
    if count > 0
      {
        count: count,
        message: I18n.t("simplefin_items.reconciled_status.message", count: count)
      }
    else
      { count: 0 }
    end
  end

  # Count stale pending transactions (>8 days old) across all linked accounts
  # Returns { count: N, accounts: [names] } or { count: 0 } if none
  def stale_pending_status(days: 8)
    # Get all accounts linked to this SimpleFIN item
    # Eager-load both association paths to avoid N+1 on current_account method
    linked_accounts = simplefin_accounts.includes(:account, :linked_account).filter_map(&:current_account)
    return { count: 0 } if linked_accounts.empty?

    # Batch query to avoid N+1
    account_ids = linked_accounts.map(&:id)
    counts_by_account = Entry.stale_pending(days: days)
      .where(excluded: false)
      .where(account_id: account_ids)
      .group(:account_id)
      .count

    account_counts = linked_accounts
      .map { |account| { account: account, count: counts_by_account[account.id].to_i } }
      .select { |ac| ac[:count] > 0 }

    total = account_counts.sum { |ac| ac[:count] }
    if total > 0
      {
        count: total,
        accounts: account_counts.map { |ac| ac[:account].name },
        message: I18n.t("simplefin_items.stale_pending_status.message", count: total, days: days)
      }
    else
      { count: 0 }
    end
  end

  private
    # Parse sync_stats, handling cases where it might be a raw JSON string
    # (e.g., from console testing or bypassed serialization)
    def parse_sync_stats(sync_stats)
      return nil if sync_stats.blank?
      return sync_stats if sync_stats.is_a?(Hash)

      if sync_stats.is_a?(String)
        JSON.parse(sync_stats) rescue nil
      end
    end

    def remove_simplefin_item
      # SimpleFin doesn't require server-side cleanup like Plaid
      # The access URL just becomes inactive
    end
end
