class TinkoffInvestItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater, ProviderDisconnectable

  self.supports_discard = false

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good
  enum :environment, { live: "live", sandbox: "sandbox" }, default: :live

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :raw_accounts_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :tinkoff_invest_accounts, dependent: :destroy

  validates :api_key, presence: true, on: :create
  validates :base_url, format: { with: /\Ahttps?:\/\/\S+\z/i }, allow_blank: true

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.where.not(api_key: [ nil, "" ]) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def credentials_configured?
    api_key.present?
  end

  def effective_base_url
    base_url.presence || (sandbox? ? Provider::TinkoffInvest::PortfolioClient::SANDBOX_BASE_URL : Provider::TinkoffInvest::PortfolioClient::LIVE_BASE_URL)
  end

  def import_latest_data
    provider = tinkoff_invest_provider
    raise Provider::TinkoffInvest::PortfolioClient::ConfigurationError, "T-Invest API token is not configured" unless provider

    TinkoffInvestItem::Importer.new(self, provider: provider).import
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "TinkoffInvestItem #{id} - Failed to import data: #{e.message}",
      source: "tinkoff_invest",
      family: family,
      provider_key: "tinkoff_invest"
    )
    raise
  end

  def process_accounts
    return [] if tinkoff_invest_accounts.empty?

    linked_tinkoff_invest_accounts.includes(account_provider: :account).each_with_object([]) do |tinkoff_account, results|
      account = tinkoff_account.current_account
      next unless account
      next if account.pending_deletion? || account.disabled?

      begin
        result = TinkoffInvestAccount::Processor.new(tinkoff_account).process
        results << { tinkoff_invest_account_id: tinkoff_account.id, success: true, result: result }
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "TinkoffInvestItem #{id} - Failed to process account #{tinkoff_account.id}: #{e.message}",
          source: "tinkoff_invest",
          family: family,
          provider_key: "tinkoff_invest",
          account_provider_id: tinkoff_account.account_provider&.id
        )
        results << { tinkoff_invest_account_id: tinkoff_account.id, success: false, error: e.message }
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
          message: "TinkoffInvestItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}",
          source: "tinkoff_invest",
          family: family,
          provider_key: "tinkoff_invest",
          account_id: account.id
        )
        results << { account_id: account.id, success: false, error: e.message }
      end
    end
  end

  def accounts
    loaded_accounts = tinkoff_invest_accounts.loaded? ? tinkoff_invest_accounts : tinkoff_invest_accounts.includes(:account, :linked_account)
    loaded_accounts.filter_map(&:current_account).uniq
  end

  def linked_tinkoff_invest_accounts
    tinkoff_invest_accounts.joins(:account_provider)
  end

  def unlinked_tinkoff_invest_accounts
    tinkoff_invest_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def linked_accounts_count
    linked_tinkoff_invest_accounts.count
  end

  def unlinked_accounts_count
    unlinked_tinkoff_invest_accounts.count
  end

  def total_accounts_count
    tinkoff_invest_accounts.count
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("tinkoff_invest_items.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("tinkoff_invest_items.sync_status.all_linked", count: linked)
    else
      I18n.t("tinkoff_invest_items.sync_status.partial", linked: linked, unlinked: unlinked)
    end
  end

  def institution_display_name
    I18n.t("tinkoff_invest_items.defaults.name")
  end
end
