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
    encrypts :raw_institution_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :open_banking_io_accounts, dependent: :destroy
  has_many :accounts, through: :open_banking_io_accounts

  validates :name, presence: true
  validates :api_base_url, :api_key, :private_key, presence: true, on: :create
  validate :api_base_url_pinned_to_open_banking_io

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_open_banking_io_data
    provider = open_banking_io_provider
    unless provider
      Rails.logger.error "OpenBankingIoItem #{id} - Cannot import: open-banking.io provider is not configured"
      raise StandardError.new("open-banking.io provider is not configured")
    end

    OpenBankingIoItem::Importer.new(self, open_banking_io_provider: provider).import
  rescue => e
    Rails.logger.error "OpenBankingIoItem #{id} - Failed to import data: #{e.message}"
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
      Rails.logger.error "OpenBankingIoItem #{id} - Failed to process account #{open_banking_io_account.id}: #{e.class} - #{e.message}"
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
      Rails.logger.error "OpenBankingIoItem #{id} - Failed to schedule sync for account #{account.id}: #{e.class} - #{e.message}"
      { account_id: account.id, success: false, error: I18n.t("open_banking_io_item.errors.account_sync_schedule_failed") }
    end
  end

  def upsert_open_banking_io_snapshot!(accounts_snapshot)
    assign_attributes(raw_payload: accounts_snapshot)
    save!
  end

  def has_completed_initial_setup?
    accounts.any?
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
    open_banking_io_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    open_banking_io_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    open_banking_io_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    open_banking_io_accounts.includes(:account)
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

    # Model-layer SSRF defense-in-depth: reject any api_base_url that isn't pinned
    # to open-banking.io, even if a caller bypasses the controller's guard.
    def api_base_url_pinned_to_open_banking_io
      return if api_base_url.blank?
      return if self.class.allowed_api_base_url?(api_base_url)

      errors.add(:api_base_url, :invalid)
    end
end
