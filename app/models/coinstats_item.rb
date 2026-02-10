# Represents a CoinStats API connection for a family.
# Stores credentials and manages associated crypto wallet accounts.
class CoinstatsItem < ApplicationRecord
  include Syncable, Provided, Unlinking

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Checks if ActiveRecord Encryption is properly configured.
  # @return [Boolean] true if encryption keys are available
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured
  encrypts :api_key, deterministic: true if encryption_ready?

  validates :name, presence: true
  validates :api_key, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :coinstats_accounts, dependent: :destroy
  has_many :accounts, through: :coinstats_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  # Schedules this item for async deletion.
  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  # Fetches latest wallet data from CoinStats API and updates local records.
  # @raise [StandardError] if provider is not configured or import fails
  def import_latest_coinstats_data
    provider = coinstats_provider
    unless provider
      Rails.logger.error "CoinstatsItem #{id} - Cannot import: CoinStats provider is not configured"
      raise StandardError.new("CoinStats provider is not configured")
    end
    CoinstatsItem::Importer.new(self, coinstats_provider: provider).import
  rescue => e
    Rails.logger.error "CoinstatsItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  # Processes holdings for all linked visible accounts.
  # @return [Array<Hash>] Results with success status per account
  def process_accounts
    return [] if coinstats_accounts.empty?

    results = []
    coinstats_accounts.includes(:account).joins(:account).merge(Account.visible).each do |coinstats_account|
      begin
        result = CoinstatsAccount::Processor.new(coinstats_account).process
        results << { coinstats_account_id: coinstats_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "CoinstatsItem #{id} - Failed to process account #{coinstats_account.id}: #{e.message}"
        results << { coinstats_account_id: coinstats_account.id, success: false, error: e.message }
      end
    end

    results
  end

  # Queues balance sync jobs for all visible accounts.
  # @param parent_sync [Sync, nil] Parent sync for tracking
  # @param window_start_date [Date, nil] Start of sync window
  # @param window_end_date [Date, nil] End of sync window
  # @return [Array<Hash>] Results with success status per account
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "CoinstatsItem #{id} - Failed to schedule sync for wallet #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  # Persists raw API response for debugging and reprocessing.
  # @param accounts_snapshot [Hash] Raw API response data
  def upsert_coinstats_snapshot!(accounts_snapshot)
    assign_attributes(raw_payload: accounts_snapshot)
    save!
  end

  # @return [Boolean] true if at least one account has been linked
  def has_completed_initial_setup?
    accounts.any?
  end

  # @return [String] Human-readable summary of sync status
  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      I18n.t("coinstats_items.coinstats_item.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("coinstats_items.coinstats_item.sync_status.all_synced", count: linked_count)
    else
      I18n.t("coinstats_items.coinstats_item.sync_status.partial_sync", linked_count: linked_count, unlinked_count: unlinked_count)
    end
  end

  # @return [Integer] Number of accounts with provider links
  def linked_accounts_count
    coinstats_accounts.joins(:account_provider).count
  end

  # @return [Integer] Number of accounts without provider links
  def unlinked_accounts_count
    coinstats_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  # @return [Integer] Total number of coinstats accounts
  def total_accounts_count
    coinstats_accounts.count
  end

  # @return [String] Display name for the CoinStats connection
  def institution_display_name
    name.presence || "CoinStats"
  end

  # @return [Boolean] true if API key is set
  def credentials_configured?
    api_key.present?
  end
end
