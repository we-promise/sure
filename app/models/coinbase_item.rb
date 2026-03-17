class CoinbaseItem < ApplicationRecord
  include Syncable, Provided, Unlinking

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Helper to detect if ActiveRecord Encryption is configured for this app
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured
  # api_key uses deterministic encryption for querying, api_secret uses standard encryption
  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :api_secret
  end

  validates :name, presence: true
  validates :api_key, presence: true
  validates :api_secret, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :coinbase_accounts, dependent: :destroy
  has_many :accounts, through: :coinbase_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_coinbase_data
    provider = coinbase_provider
    unless provider
      Rails.logger.error "CoinbaseItem #{id} - Cannot import: credentials not configured"
      raise StandardError.new("Coinbase credentials not configured")
    end

    CoinbaseItem::Importer.new(self, coinbase_provider: provider).import
  rescue => e
    Rails.logger.error "CoinbaseItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    Rails.logger.info "CoinbaseItem #{id} - process_accounts: total coinbase_accounts=#{coinbase_accounts.count}"

    return [] if coinbase_accounts.empty?

    # Debug: log all coinbase accounts and their linked status
    coinbase_accounts.each do |ca|
      Rails.logger.info(
        "CoinbaseItem #{id} - coinbase_account #{ca.id}: " \
        "name='#{ca.name}' balance=#{ca.current_balance} " \
        "account_provider=#{ca.account_provider&.id || 'nil'} " \
        "account=#{ca.account&.id || 'nil'}"
      )
    end

    linked = coinbase_accounts.joins(:account).merge(Account.visible)
    Rails.logger.info "CoinbaseItem #{id} - found #{linked.count} linked visible accounts to process"

    results = []
    linked.each do |coinbase_account|
      begin
        Rails.logger.info "CoinbaseItem #{id} - processing coinbase_account #{coinbase_account.id}"
        result = CoinbaseAccount::Processor.new(coinbase_account).process
        results << { coinbase_account_id: coinbase_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "CoinbaseItem #{id} - Failed to process account #{coinbase_account.id}: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
        results << { coinbase_account_id: coinbase_account.id, success: false, error: e.message }
      end
    end

    results
  end

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
        Rails.logger.error "CoinbaseItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_coinbase_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    # Setup is complete if we have any linked accounts
    accounts.any?
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      I18n.t("coinbase_items.coinbase_item.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("coinbase_items.coinbase_item.sync_status.all_synced", count: linked_count)
    else
      I18n.t("coinbase_items.coinbase_item.sync_status.partial_sync", linked_count: linked_count, unlinked_count: unlinked_count)
    end
  end

  def linked_accounts_count
    coinbase_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    coinbase_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    coinbase_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    coinbase_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      "No institutions connected"
    when 1
      institutions.first["name"] || institutions.first["institution_name"] || "1 institution"
    else
      "#{institutions.count} institutions"
    end
  end

  def credentials_configured?
    api_key.present? && api_secret.present?
  end

  # Default institution metadata for Coinbase
  def set_coinbase_institution_defaults!
    update!(
      institution_name: "Coinbase",
      institution_domain: "coinbase.com",
      institution_url: "https://www.coinbase.com",
      institution_color: "#0052FF"
    )
  end
end
