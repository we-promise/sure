# frozen_string_literal: true

class CoinspotItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :api_secret
    encrypts :raw_payload
  end

  validates :name, presence: true
  validates :api_key, presence: true
  validates :api_secret, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :coinspot_accounts, dependent: :destroy
  has_many :accounts, through: :coinspot_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }
  scope :credentials_configured, -> { where.not(api_key: [ nil, "" ]).where.not(api_secret: nil) }

  before_validation :strip_credentials

  # Marks the connection for asynchronous deletion rather than destroying it
  # inline, so a large item with many accounts doesn't block the request.
  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  # Fetches and imports this connection's latest balances and transaction
  # history from CoinSpot. Raises if credentials aren't configured or the
  # import itself fails -- callers (the syncer) are responsible for turning
  # that into a sync status rather than this method swallowing it.
  def import_latest_coinspot_data
    provider = coinspot_provider
    raise StandardError, "CoinSpot credentials not configured" unless provider

    CoinspotItem::Importer.new(self, coinspot_provider: provider).import
  rescue StandardError => e
    Rails.logger.error "CoinspotItem #{id} - Failed to import: #{e.full_message}"
    raise
  end

  # Processes holdings and activity for every linked, visible CoinSpot
  # account. Returns a per-account result array rather than raising, so one
  # account's failure doesn't stop the rest from processing.
  def process_accounts
    return [] if coinspot_accounts.empty?

    results = []
    coinspot_accounts.joins(:account).merge(Account.visible).each do |coinspot_account|
      begin
        result = CoinspotAccount::Processor.new(coinspot_account).process
        results << { coinspot_account_id: coinspot_account.id, success: true, result: result }
      rescue StandardError => e
        Rails.logger.error "CoinspotItem #{id} - Failed to process account #{coinspot_account.id}: #{e.full_message}"
        results << { coinspot_account_id: coinspot_account.id, success: false, error: e.message }
      end
    end

    results
  end

  # Queues a Sync for every linked, visible account, chained under
  # `parent_sync` if given. Returns a per-account result array; a single
  # account's scheduling failure is logged and reported without blocking
  # the rest.
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    accounts.visible.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue StandardError => e
      Rails.logger.error "CoinspotItem #{id} - Failed to schedule sync for account #{account.id}: #{e.full_message}"
      { account_id: account.id, success: false, error: e.message }
    end
  end

  # Stores the raw status/balances payload from the last successful fetch.
  def upsert_coinspot_snapshot!(payload)
    update!(raw_payload: payload)
  end

  # True once at least one CoinSpot account has been imported as a Sure account.
  def has_completed_initial_setup?
    accounts.any?
  end

  # Localized one-line summary of this connection's account sync state, for
  # the settings panel and account-list rows.
  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("coinspot_items.coinspot_item.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("coinspot_items.coinspot_item.sync_status.all_synced", count: linked)
    else
      I18n.t("coinspot_items.coinspot_item.sync_status.partial_sync", linked_count: linked, unlinked_count: unlinked)
    end
  end

  # Number of CoinSpot accounts already linked to a Sure account.
  def linked_accounts_count
    coinspot_accounts.joins(:account_provider).count
  end

  # Number of CoinSpot accounts still needing account setup.
  def unlinked_accounts_count
    coinspot_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  # Total CoinSpot accounts discovered for this connection.
  def total_accounts_count
    coinspot_accounts.count
  end

  # Active, linked accounts whose balance currently reflects a stale
  # (non-exact-date) FX conversion rather than the exact-date rate.
  def stale_rate_accounts
    coinspot_accounts
      .joins(:account)
      .where(accounts: { status: "active" })
      .where("coinspot_accounts.extra -> 'coinspot' ->> 'stale_rate' = 'true'")
  end

  # Best available label for the connection: institution name, falling back
  # to domain, then the connection's own name.
  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  # True when both API credentials are present (not necessarily valid).
  def credentials_configured?
    api_key.to_s.strip.present? && api_secret.to_s.strip.present?
  end

  # The next nonce to sign a request with. CoinSpot rejects a nonce that
  # doesn't strictly increase, so this is generated under a row lock and
  # compared against the last one used to guarantee monotonicity even when
  # requests race (e.g. a manual sync overlapping a scheduled one).
  def next_nonce!
    with_lock do
      candidate = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
      candidate = last_nonce.to_i + 1 if candidate <= last_nonce.to_i
      update!(last_nonce: candidate)
      candidate.to_s
    end
  end

  # Sets the standard CoinSpot branding/institution fields on a newly-created
  # connection (name, domain, URL, brand color).
  def set_coinspot_institution_defaults!
    update!(
      institution_name: "CoinSpot",
      institution_domain: "coinspot.com.au",
      institution_url: "https://www.coinspot.com.au",
      institution_color: "#0F6BFF"
    )
  end

  private

    # Trims whitespace a user may have pasted around their API credentials.
    def strip_credentials
      self.api_key = api_key.to_s.strip if api_key_changed? && !api_key.nil?
      self.api_secret = api_secret.to_s.strip if api_secret_changed? && !api_secret.nil?
    end
end
