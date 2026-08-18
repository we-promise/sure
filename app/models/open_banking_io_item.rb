class OpenBankingIoItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  # SSRF guard: the api_base_url from the pasted credentials.json is used verbatim
  # by the SDK's HTTP client, so it must be pinned to the real open-banking.io
  # service (exactly open-banking.io or a subdomain, over https). This is the one
  # source of truth reused by the controller's credential-parsing guard.
  ALLOWED_API_HOST = "open-banking.io".freeze

  # Whether +url+ is a permitted open-banking.io API base URL: https and a host
  # that is exactly open-banking.io or one of its subdomains. Rejects internal
  # IPs, plain http, and look-alikes such as "open-banking.io.evil.com".
  def self.allowed_api_base_url?(url)
    uri = URI.parse(url.to_s)
    return false unless uri.is_a?(URI::HTTPS)

    host = uri.host.to_s.downcase
    host == ALLOWED_API_HOST || host.end_with?(".#{ALLOWED_API_HOST}")
  rescue URI::InvalidURIError
    false
  end

  # Virtual field: the "add connection" form is a single textarea where the user
  # pastes their exported credentials.json bundle. The controller parses it into
  # api_base_url / api_key / private_key before saving.
  attr_accessor :credentials_json

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    # Non-deterministic encryption: nothing queries these columns by value
    # (no `where(api_key:)` / `where(api_base_url:)`), so deterministic mode
    # would only weaken them by leaking equality. Matches :private_key.
    encrypts :api_base_url
    encrypts :api_key
    encrypts :private_key
    encrypts :raw_payload
  end

  belongs_to :family
  has_many :open_banking_io_accounts, dependent: :destroy
  has_many :accounts, through: :open_banking_io_accounts

  validates :name, presence: true
  validates :api_base_url, :api_key, :private_key, presence: true, on: :create
  validate :api_base_url_pinned_to_open_banking_io

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }

  # The memoized provider holds a parsed EC key built from these columns.
  after_save :reset_open_banking_io_provider!, if: -> {
    saved_change_to_api_base_url? || saved_change_to_api_key? || saved_change_to_private_key?
  }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end


  # Provider sync/import diagnostics belong on /settings/debug where support can filter by
  # provider and family, not only in the application log. Mirrors UpItem.
  def capture_provider_error(message, error: nil, level: "error", **metadata)
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: level,
      message: message,
      source: self.class.name,
      provider_key: "open_banking_io",
      family: family,
      account_provider: metadata.delete(:account_provider),
      metadata: {
        open_banking_io_item_id: id,
        error_class: error&.class&.name,
        error_message: error&.message
      }.merge(metadata).compact
    )
  end

  def import_latest_open_banking_io_data
    provider = open_banking_io_provider
    unless provider
      capture_provider_error("Cannot import: open-banking.io provider is not configured")
      raise StandardError.new("open-banking.io provider is not configured")
    end

    OpenBankingIoItem::Importer.new(self, open_banking_io_provider: provider).import
  rescue => e
    capture_provider_error("Failed to import open-banking.io data", error: e)
    raise
  end

  def process_accounts
    return [] if open_banking_io_accounts.empty?

    open_banking_io_accounts.joins(:account).merge(Account.visible).map do |open_banking_io_account|
      result = OpenBankingIoAccount::Processor.new(open_banking_io_account).process
      if result.is_a?(Hash) && result.with_indifferent_access[:success] == false
        { open_banking_io_account_id: open_banking_io_account.id, success: false, error: I18n.t("open_banking_io_item.errors.account_processing_failed") }
      else
        { open_banking_io_account_id: open_banking_io_account.id, success: true, result: result }
      end
    rescue => e
      capture_provider_error(
        "Failed to process open-banking.io account",
        error: e,
        open_banking_io_account_id: open_banking_io_account.id,
        account_provider: open_banking_io_account.account_provider
      )
      { open_banking_io_account_id: open_banking_io_account.id, success: false, error: I18n.t("open_banking_io_item.errors.account_processing_failed") }
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    accounts.visible.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue => e
      capture_provider_error("Failed to schedule open-banking.io account sync", error: e, account_id: account.id)
      { account_id: account.id, success: false, error: I18n.t("open_banking_io_item.errors.account_sync_schedule_failed") }
    end
  end

  # Refreshes the discovered provider accounts for the interactive linking screens.
  # Returns nil on success, or a translated error message to show the user.
  #
  # Lives here rather than in the controller so it shares the importer's preload and
  # transaction, and so failures land on /settings/debug like every other sync failure.
  def refresh_accounts_from_provider!
    provider = open_banking_io_provider
    return I18n.t("open_banking_io_items.setup_accounts.no_credentials") unless provider

    OpenBankingIoItem::Importer.new(self, open_banking_io_provider: provider).refresh_accounts_only
    nil
  rescue => e
    capture_provider_error("Failed to refresh open-banking.io accounts", error: e)
    I18n.t("open_banking_io_items.setup_accounts.api_error")
  end

  def upsert_open_banking_io_snapshot!(accounts_snapshot)
    assign_attributes(raw_payload: accounts_snapshot)
    save!
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts.zero?
      I18n.t("open_banking_io_item.sync_status.no_accounts")
    elsif unlinked_count.zero?
      I18n.t("open_banking_io_item.sync_status.all_synced", count: linked_count)
    else
      I18n.t("open_banking_io_item.sync_status.partial", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def linked_accounts_count
    account_counts[:linked]
  end

  def unlinked_accounts_count
    account_counts[:unlinked]
  end

  def total_accounts_count
    account_counts[:total]
  end

  # Part of the provider-item interface reflected over by ProviderConnectionStatus.
  # open-banking.io aggregates many banks per connection, so the connection's own name is
  # the only meaningful label here -- see #institution_summary for the per-bank breakdown.
  def institution_display_name
    name
  end

  def connected_institutions
    # Memoized and without the eager-loaded :account it never touched: the item partial
    # calls this once directly and again through #institution_summary.
    @connected_institutions ||= open_banking_io_accounts
      .where.not(institution_metadata: nil)
      .map(&:institution_metadata)
      .uniq { |inst| inst["id"] || inst["name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("open_banking_io_item.institution_summary.none")
    when 1
      institutions.first["name"].presence || I18n.t("open_banking_io_item.institution_summary.one")
    else
      I18n.t("open_banking_io_item.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    api_base_url.present? && api_key.present? && private_key.present?
  end

  private

    # One query for all three counts. The item partial renders every one of them plus
    # #sync_status_summary, which was four separate COUNTs per connection. Mirrors UpItem.
    def account_counts
      @account_counts ||= begin
        rows = open_banking_io_accounts
                 .left_joins(:account_provider)
                 .pluck(Arel.sql("account_providers.id IS NOT NULL"))

        linked = rows.count { |has_provider| has_provider }
        { linked: linked, unlinked: rows.size - linked, total: rows.size }
      end
    end

    # Model-layer SSRF defense-in-depth: reject any api_base_url that isn't pinned
    # to open-banking.io, even if a caller bypasses the controller's guard.
    def api_base_url_pinned_to_open_banking_io
      return if api_base_url.blank?
      return if self.class.allowed_api_base_url?(api_base_url)

      errors.add(:api_base_url, :invalid)
    end
end
