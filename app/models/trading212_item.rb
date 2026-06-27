class Trading212Item < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good
  enum :environment, { live: "live", demo: "demo" }, default: :live

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :api_secret
    encrypts :raw_instruments_payload
  end

  belongs_to :family
  has_many :trading212_accounts, dependent: :destroy

  validates :api_key, presence: true, on: :create
  validates :api_secret, presence: true, on: :create

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.where.not(api_key: [ nil, "" ]) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def credentials_configured?
    api_key.present? && api_secret.present?
  end

  def import_latest_data
    provider = trading212_provider
    raise StandardError, "Trading 212 provider is not configured" unless provider

    Trading212Item::Importer.new(self, provider: provider).import
  rescue => e
    Rails.logger.error("Trading212Item #{id} - Failed to import data: #{e.message}")
    raise
  end

  def process_accounts
    return [] if trading212_accounts.empty?

    linked_trading212_accounts.includes(account_provider: :account).each_with_object([]) do |t212_account, results|
      account = t212_account.current_account
      next unless account
      next if account.pending_deletion? || account.disabled?

      begin
        result = Trading212Account::Processor.new(t212_account).process
        results << { trading212_account_id: t212_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error("Trading212Item #{id} - Failed to process account #{t212_account.id}: #{e.message}")
        results << { trading212_account_id: t212_account.id, success: false, error: e.message }
      end
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.reject { |account| account.pending_deletion? || account.disabled? }.each_with_object([]) do |account, results|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error("Trading212Item #{id} - Failed to schedule sync for account #{account.id}: #{e.message}")
        results << { account_id: account.id, success: false, error: e.message }
      end
    end
  end

  def accounts
    trading212_accounts.includes(account_provider: :account).filter_map(&:current_account).uniq
  end

  def linked_trading212_accounts
    trading212_accounts.joins(:account_provider)
  end

  def linked_accounts_count
    trading212_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    trading212_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    trading212_accounts.count
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("trading212_items.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("trading212_items.sync_status.all_linked", count: linked)
    else
      I18n.t("trading212_items.sync_status.partial", linked: linked, unlinked: unlinked)
    end
  end

  def institution_display_name
    I18n.t("trading212_items.defaults.name")
  end

  def instruments_map
    @instruments_map ||= Array(raw_instruments_payload).each_with_object({}) do |instrument, map|
      map[instrument["ticker"]] = instrument
    end
  end
end
