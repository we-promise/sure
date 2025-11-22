class SimplefinItem < ApplicationRecord
  include Syncable, Provided
  include SimplefinItem::Unlinking

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Virtual attribute for the setup token form field
  attr_accessor :setup_token

  # Helper to detect if ActiveRecord Encryption is configured for this app
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured (credentials OR env vars)
  if encryption_ready?
    encrypts :access_url, deterministic: true
  end

  validates :name, presence: true
  validates :access_url, presence: true, on: :create

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
