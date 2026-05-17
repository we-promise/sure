class IbkrItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :query_id, deterministic: true
    encrypts :token
    encrypts :raw_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :ibkr_accounts, dependent: :destroy

  validates :name, presence: true
  validates :query_id, presence: true, on: :create
  validates :token, presence: true, on: :create

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.where.not(query_id: [ nil, "" ]).where.not(token: nil) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def credentials_configured?
    query_id.present? && token.present?
  end

  def import_latest_ibkr_data
    provider = ibkr_provider
    raise StandardError, "IBKR provider is not configured" unless provider

    IbkrItem::Importer.new(self, ibkr_provider: provider).import
  rescue => e
    Rails.logger.error("IbkrItem #{id} - Failed to import data: #{e.message}")
    raise
  end

  def process_accounts
    return [] if ibkr_accounts.empty?

    linked_ibkr_accounts.includes(account_provider: :account).each_with_object([]) do |ibkr_account, results|
      account = ibkr_account.current_account
      next unless account
      next if account.pending_deletion? || account.disabled?

      begin
        result = IbkrAccount::Processor.new(ibkr_account).process
        results << { ibkr_account_id: ibkr_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error("IbkrItem #{id} - Failed to process account #{ibkr_account.id}: #{e.message}")
        results << { ibkr_account_id: ibkr_account.id, success: false, error: e.message }
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
        Rails.logger.error("IbkrItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}")
        results << { account_id: account.id, success: false, error: e.message }
      end
    end
  end

  def upsert_ibkr_snapshot!(payload)
    update!(raw_payload: payload, status: :good)
  end

  def accounts
    ibkr_accounts.includes(account_provider: :account).filter_map(&:current_account).uniq
  end

  def linked_ibkr_accounts
    ibkr_accounts.joins(:account_provider)
  end

  def linked_accounts_count
    ibkr_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    ibkr_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    ibkr_accounts.count
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts.zero?
      I18n.t("ibkr_items.sync_status.no_accounts")
    elsif unlinked_count.zero?
      I18n.t("ibkr_items.sync_status.all_linked", count: linked_count)
    else
      I18n.t("ibkr_items.sync_status.partial", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def institution_display_name
    I18n.t("ibkr_items.defaults.name")
  end
end
