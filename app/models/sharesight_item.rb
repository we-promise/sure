class SharesightItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater, ProviderDisconnectable

  # Disconnecting keeps the accounts and their history. Deleting them isn't supported yet.
  self.supports_discard = false

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :client_id, deterministic: true
    encrypts :client_secret
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :sharesight_accounts, dependent: :destroy

  validates :client_id, presence: true, on: :create
  validates :client_secret, presence: true, on: :create

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.where.not(client_id: [ nil, "" ]) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def credentials_configured?
    client_id.present? && client_secret.present?
  end

  def import_latest_data
    provider = sharesight_provider
    raise Provider::Sharesight::ConfigurationError, "Sharesight API client is not configured" unless provider

    SharesightItem::Importer.new(self, provider: provider).import
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "SharesightItem #{id} - Failed to import data: #{e.message}",
      source: "sharesight",
      family: family,
      provider_key: "sharesight"
    )
    raise
  end

  def process_accounts
    return [] if sharesight_accounts.empty?

    linked_sharesight_accounts.includes(account_provider: :account).each_with_object([]) do |sharesight_account, results|
      account = sharesight_account.current_account
      next unless account
      next if account.pending_deletion? || account.disabled?

      begin
        result = SharesightAccount::Processor.new(sharesight_account).process
        results << { sharesight_account_id: sharesight_account.id, success: true, result: result }
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "SharesightItem #{id} - Failed to process account #{sharesight_account.id}: #{e.message}",
          source: "sharesight",
          family: family,
          provider_key: "sharesight",
          account_provider_id: sharesight_account.account_provider&.id
        )
        results << { sharesight_account_id: sharesight_account.id, success: false, error: e.message }
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
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "SharesightItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}",
          source: "sharesight",
          family: family,
          provider_key: "sharesight",
          account_id: account.id
        )
        results << { account_id: account.id, success: false, error: e.message }
      end
    end
  end

  def accounts
    sharesight_accounts.includes(account_provider: :account).filter_map(&:current_account).uniq
  end

  def linked_sharesight_accounts
    sharesight_accounts.joins(:account_provider)
  end

  def unlinked_sharesight_accounts
    sharesight_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def linked_accounts_count
    linked_sharesight_accounts.count
  end

  def unlinked_accounts_count
    unlinked_sharesight_accounts.count
  end

  def total_accounts_count
    sharesight_accounts.count
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("sharesight_items.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("sharesight_items.sync_status.all_linked", count: linked)
    else
      I18n.t("sharesight_items.sync_status.partial", linked: linked, unlinked: unlinked)
    end
  end

  def institution_display_name
    I18n.t("sharesight_items.defaults.name")
  end
end
