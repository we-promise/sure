class BinanceItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :api_secret
  end

  validates :name, presence: true
  validates :api_key, presence: true
  validates :api_secret, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :binance_accounts, dependent: :destroy
  has_many :accounts, through: :binance_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_binance_data
    provider = binance_provider
    unless provider
      Rails.logger.error "BinanceItem #{id} - Cannot import: credentials not configured"
      raise StandardError, "Binance credentials not configured"
    end

    BinanceItem::Importer.new(self, binance_provider: provider).import
  rescue => e
    Rails.logger.error "BinanceItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if binance_accounts.empty?

    results = []
    linked_accounts = binance_accounts.includes(:account).joins(:account).merge(Account.visible)

    linked_accounts.each do |binance_account|
      begin
        result = BinanceAccount::Processor.new(binance_account).process
        results << { binance_account_id: binance_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "BinanceItem #{id} - Failed to process account #{binance_account.id}: #{e.message}"
        results << { binance_account_id: binance_account.id, success: false, error: e.message }
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
        Rails.logger.error "BinanceItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_binance_snapshot!(snapshot)
    assign_attributes(raw_payload: snapshot)
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
      I18n.t("binance_items.binance_item.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("binance_items.binance_item.sync_status.all_synced", count: linked_count)
    else
      I18n.t("binance_items.binance_item.sync_status.partial_sync", linked_count: linked_count, unlinked_count: unlinked_count)
    end
  end

  def linked_accounts_count
    binance_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    binance_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    binance_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def credentials_configured?
    api_key.present? && api_secret.present?
  end

  def set_binance_institution_defaults!
    update!(
      institution_name: "Binance",
      institution_domain: "binance.com",
      institution_url: "https://www.binance.com",
      institution_color: "#F0B90B"
    )
  end
end
