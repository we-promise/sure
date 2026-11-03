class EtoroItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :user_key
    encrypts :raw_instruments_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :etoro_accounts, dependent: :destroy

  validates :api_key, presence: true, on: :create
  validates :user_key, presence: true, on: :create

  before_destroy :release_priced_securities

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.where.not(api_key: [ nil, "" ]) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def credentials_configured?
    api_key.present? && user_key.present?
  end

  def import_latest_data
    provider = etoro_provider
    raise StandardError, "eToro provider is not configured" unless provider

    EtoroItem::Importer.new(self, provider: provider).import
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "EtoroItem #{id} - Failed to import data: #{e.message}",
      source: "etoro",
      family: family,
      provider_key: "etoro"
    )
    raise
  end

  def process_accounts
    return [] if etoro_accounts.empty?

    # Main accounts go before their copies: a disabled copy's pass queues
    # the sync of the account it rebuilds (see EtoroAccount::Processor),
    # whose first day needs the transfers the main account's pass makes.
    copies, mains = linked_etoro_accounts.includes(account_provider: :account).partition(&:copy?)
    results = (mains + copies).each_with_object([]) do |etoro_account, results|
      account = etoro_account.current_account
      next unless account
      next if account.pending_deletion?
      next if account.disabled? && !etoro_account.processed_while_disabled?

      begin
        result = EtoroAccount::Processor.new(etoro_account).process
        results << { etoro_account_id: etoro_account.id, success: true, result: result }
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "EtoroItem #{id} - Failed to process account #{etoro_account.id}: #{e.message}",
          source: "etoro",
          family: family,
          provider_key: "etoro",
          account_provider_id: etoro_account.account_provider&.id
        )
        results << { etoro_account_id: etoro_account.id, success: false, error: e.message }
      end
    end

    discard_left_securities
    results
  end

  # The securities the connection's accounts have left, as after a change of
  # own_securities or of how a symbol resolves: those with no units in any
  # of their holdings, which the holdings import closes with a row of zero
  # units when eToro stops reporting them and an account shown by its
  # copies, which keeps no trades, never moves. They go when nothing else
  # holds or trades them (see EtoroAccount::DataHelpers.discard_unused_securities).
  def discard_left_securities
    account_ids = accounts.map(&:id)
    left = Holding.where(account_id: account_ids).group(:security_id).having("BOOL_AND(holdings.qty = 0)").pluck(:security_id)
    EtoroAccount::DataHelpers.discard_unused_securities(left, accounts: account_ids)
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "warn",
      message: "EtoroItem #{id} - Failed to let go of the securities its accounts left: #{e.class} - #{e.message}",
      source: "etoro",
      family: family,
      provider_key: "etoro"
    )
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
          message: "EtoroItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}",
          source: "etoro",
          family: family,
          provider_key: "etoro",
          account_id: account.id
        )
        results << { account_id: account.id, success: false, error: e.message }
      end
    end
  end

  def accounts
    etoro_accounts.includes(account_provider: :account).filter_map(&:current_account).uniq
  end

  def linked_etoro_accounts
    etoro_accounts.joins(:account_provider)
  end

  def linked_accounts_count
    etoro_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    etoro_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    etoro_accounts.count
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("etoro_items.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("etoro_items.sync_status.all_linked", count: linked)
    else
      I18n.t("etoro_items.sync_status.partial", linked: linked, unlinked: unlinked)
    end
  end

  def institution_display_name
    I18n.t("etoro_items.defaults.name")
  end

  # Whether Sure has recorded a copy-trading portfolio of the connection's
  # accounts. The records are the only history of a copy and go with the
  # connection, as eToro cannot send them again (see EtoroPortfolioSnapshot).
  def copies_recorded?
    EtoroPortfolioSnapshot.mirrors.exists?(etoro_account_id: etoro_accounts.select(:id))
  end

  # eToro instrument metadata keyed by instrument ID (as a string).
  def instruments_map
    raw_instruments_payload.is_a?(Hash) ? raw_instruments_payload : {}
  end

  # The price histories of the instruments whose closes go on a security
  # (see EtoroItem::PriceHistoryImporter).
  def priced_histories
    instruments_map.values.filter_map do |details|
      history = details["price_history"] if details.is_a?(Hash)
      history if history.is_a?(Hash) && history["security_id"].present?
    end
  end

  # Hands back eToro's prices once no account of this connection values
  # holdings with them, without asking eToro anything (see
  # EtoroItem::PriceHistoryImporter#release_unused).
  def release_unused_prices!
    accounts = etoro_accounts.reload.reject(&:copy?)
    in_use = accounts.any? { |etoro_account| EtoroItem::PriceHistoryImporter.pricing_account(etoro_account) && !etoro_account.shown_as_totals? }
    return if accounts.empty? || in_use

    EtoroItem::PriceHistoryImporter.new(self, accounts.first, provider: nil).release_unused
  end

  # The securities the family's other eToro connections price for an
  # account linked to them and shown by its holdings, as holdings or split
  # into copies, as after linking the account to a new connection. Their
  # prices stay when this connection stops pricing them.
  def securities_priced_elsewhere
    family.etoro_items.where.not(id: id).includes(etoro_accounts: :account_provider).each_with_object(Set.new) do |item, security_ids|
      next unless item.etoro_accounts.any? { |etoro_account| !etoro_account.copy? && etoro_account.account_provider && !etoro_account.shown_as_totals? }

      item.priced_histories.each { |history| security_ids << history["security_id"] }
    end
  end

  private

    # eToro's prices go with the connection, Sure's health checks take the
    # securities back, and the accounts valued at the prices are synced
    # again. A sync still running hands back the ones it has written once it
    # ends (see EtoroItem::PriceHistoryImporter).
    def release_priced_securities
      elsewhere = securities_priced_elsewhere
      EtoroAccount::PriceHistoryProcessor.release(priced_histories.reject { |history| elsewhere.include?(history["security_id"]) })
    end
end
