class TradeRepublicItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  # The PIN is accepted only for the authentication request. It is never
  # persisted; session restoration uses the encrypted session blob instead.
  attr_accessor :pin

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :phone_number, deterministic: true
    encrypts :session_blob
    encrypts :pending_login_state
  end

  belongs_to :family
  has_many :trade_republic_accounts, dependent: :destroy

  # QR login does not require the phone number or PIN. The account is created
  # in requires_update state first and receives its authenticated session after
  # the QR challenge is approved in the Trade Republic app.
  validates :phone_number, presence: true, unless: -> { requires_update? || session_configured? }

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.where(status: :good, pending_login_state: nil).where.not(session_blob: [ nil, "" ]) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  # Reloading represents a new persisted state; never carry an authentication
  # PIN across that boundary in the in-memory model instance.
  def reload(*)
    super.tap { @pin = nil }
  end

  def credentials_configured?
    phone_number.present? || session_configured?
  end

  def session_configured?
    session_blob.present?
  end

  def ready_for_sync?
    good? && pending_login_state.blank? && session_configured?
  end

  def import_latest_data
    provider = trade_republic_provider
    raise Provider::TradeRepublicClient::ConfigurationError, "Trade Republic connection is not configured" unless provider

    TradeRepublicItem::Importer.new(self, provider: provider).import
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "TradeRepublicItem #{id} - Failed to import data: #{e.message}",
      source: "trade_republic",
      family: family,
      provider_key: "trade_republic"
    )
    raise
  end

  def process_accounts
    return [] if trade_republic_accounts.empty?

    linked_trade_republic_accounts.includes(account_provider: :account).each_with_object([]) do |tr_account, results|
      account = tr_account.current_account
      next unless account
      next if account.pending_deletion? || account.disabled?

      begin
        result = TradeRepublicAccount::Processor.new(tr_account).process
        results << { trade_republic_account_id: tr_account.id, success: true, result: result }
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "TradeRepublicItem #{id} - Failed to process account #{tr_account.id}: #{e.message}",
          source: "trade_republic",
          family: family,
          provider_key: "trade_republic",
          account_provider_id: tr_account.account_provider&.id
        )
        results << { trade_republic_account_id: tr_account.id, success: false, error: e.message }
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
          message: "TradeRepublicItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}",
          source: "trade_republic",
          family: family,
          provider_key: "trade_republic",
          account_id: account.id
        )
        results << { account_id: account.id, success: false, error: e.message }
      end
    end
  end

  def accounts
    trade_republic_accounts.includes(account_provider: :account).filter_map(&:current_account).uniq
  end

  def linked_trade_republic_accounts
    trade_republic_accounts.joins(:account_provider)
  end

  def linked_accounts_count
    trade_republic_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    trade_republic_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    trade_republic_accounts.count
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("trade_republic_items.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("trade_republic_items.sync_status.all_linked", count: linked)
    else
      I18n.t("trade_republic_items.sync_status.partial", linked: linked, unlinked: unlinked)
    end
  end

  def institution_display_name
    I18n.t("trade_republic_items.defaults.name")
  end

  def sync_history(limit: 5)
    syncs.ordered.limit(limit)
  end

  def data_quality_summary
    positions = trade_republic_accounts.where(kind: "portfolio").flat_map { |account| Array(account.raw_positions_payload) }
    events = trade_republic_accounts.flat_map { |account| Array(account.raw_timeline_payload) }
    unknown_events = events.count do |event|
      !event.is_a?(Hash) || !TradeRepublicAccount::DataHelpers::KNOWN_ACTIVITY_CATEGORIES.include?(event["category"])
    end

    {
      positions: positions.size,
      unpriced_positions: positions.count { |position| position["price"].blank? },
      events: events.size,
      unknown_events: unknown_events,
      linked_accounts: linked_accounts_count,
      unlinked_accounts: unlinked_accounts_count
    }
  end

  def reconciliation_summary
    trade_republic_accounts.filter_map do |provider_account|
      account = provider_account.current_account
      next if account.blank?

      expected = provider_account.current_balance.to_d
      actual = account.balance.to_d
      difference = (expected - actual).abs
      {
        kind: provider_account.kind,
        account_id: account.id,
        expected: expected,
        actual: actual,
        difference: difference,
        reconciled: difference < BigDecimal("0.01")
      }
    end
  end

  def expense_summary(days: 30)
    entries = accounts.flat_map do |account|
      account.entries.where(source: "trade_republic", entryable_type: "Transaction")
        .where(date: days.days.ago.to_date..Date.current)
    end
    expenses = entries.select { |entry| entry.amount.to_d.positive? }

    {
      count: expenses.size,
      total: expenses.sum { |entry| entry.amount.to_d },
      days: days
    }
  end
end
