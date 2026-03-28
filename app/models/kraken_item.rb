class KrakenItem < ApplicationRecord
  include Syncable, Provided, Unlinking

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :api_secret
  end

  validates :name, presence: true
  validates :api_key, presence: true
  validates :api_secret, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :kraken_accounts, dependent: :destroy
  has_many :accounts, through: :kraken_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_kraken_data
    provider = kraken_provider
    unless provider
      Rails.logger.error "KrakenItem #{id} - Cannot import: credentials not configured"
      raise StandardError, "Kraken credentials not configured"
    end

    KrakenItem::Importer.new(self, kraken_provider: provider).import
  rescue => e
    Rails.logger.error "KrakenItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if kraken_accounts.empty?

    results = []
    kraken_accounts.joins(:account).merge(Account.visible).each do |kraken_account|
      begin
        result = KrakenAccount::Processor.new(kraken_account).process
        results << { kraken_account_id: kraken_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "KrakenItem #{id} - Failed to process account #{kraken_account.id}: #{e.message}"
        results << { kraken_account_id: kraken_account.id, success: false, error: e.message }
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
        Rails.logger.error "KrakenItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_kraken_snapshot!(accounts_snapshot)
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

    if total_accounts == 0
      I18n.t("kraken_items.kraken_item.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("kraken_items.kraken_item.sync_status.all_synced", count: linked_count)
    else
      I18n.t("kraken_items.kraken_item.sync_status.partial_sync", linked_count: linked_count, unlinked_count: unlinked_count)
    end
  end

  def linked_accounts_count
    kraken_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    kraken_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    kraken_accounts.count
  end

  def institution_display_name
    institution_name.presence || name
  end

  def credentials_configured?
    api_key.present? && api_secret.present?
  end

  def set_kraken_institution_defaults!
    update!(
      institution_name: "Kraken",
      institution_domain: "kraken.com",
      institution_url: "https://www.kraken.com",
      institution_color: "#1A1A1A"
    )
  end
end
