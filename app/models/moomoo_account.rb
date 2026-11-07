class MoomooAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable
  include MoomooAccount::DataHelpers

  KINDS = %w[securities futures crypto jp_margin other].freeze
  # Syncs in a row a market's trade history failed to load. Past this the
  # market no longer counts as importing; every sync still retries it.
  HISTORY_FAILURE_LIMIT = 5

  if encryption_ready?
    encrypts :raw_account_payload
    encrypts :raw_funds_payload
    encrypts :raw_positions_payload
    encrypts :raw_fills_payload
    encrypts :raw_orders_payload
    encrypts :raw_cash_logs_payload
  end

  # A trading account that isn't split by currency is one combined row. One
  # split by currency has a cash row per currency, which takes its cash and
  # cash log, and a stocks row per currency with positions or trades, which
  # takes those (see MoomooAccount::CurrencySplit).
  ROLES = %w[combined cash stocks].freeze

  # The kind of Sure account each row is set up as, with its subtype. A cash
  # row's account is a cash account, so its money counts as cash in net worth
  # like any other cash a broker holds for the user; the others are
  # brokerage accounts.
  CASH_ACCOUNTABLE = { type: "Depository", subtype: "checking" }.freeze
  INVESTMENT_ACCOUNTABLE = { type: "Investment", subtype: "brokerage" }.freeze

  belongs_to :moomoo_item
  # Each row of a trading account split by currency is linked to its own Sure
  # account. The row moomoo's data is fetched into, in the account's home
  # currency, is the primary; the others are its currency accounts and read
  # their data from it.
  belongs_to :primary_moomoo_account, class_name: "MoomooAccount", optional: true, inverse_of: :currency_accounts
  has_many :currency_accounts, class_name: "MoomooAccount", foreign_key: :primary_moomoo_account_id,
           inverse_of: :primary_moomoo_account, dependent: :destroy

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :currency, presence: true
  validates :account_kind, inclusion: { in: KINDS }
  validates :role, inclusion: { in: ROLES }
  validates :moomoo_account_id, uniqueness: { scope: :moomoo_item_id, allow_nil: true, conditions: -> { primary } }, unless: :currency_account?
  validates :currency, uniqueness: { scope: %i[moomoo_item_id moomoo_account_id role] }, if: :moomoo_account_id?

  scope :securities, -> { where(account_kind: "securities") }
  scope :primary, -> { where(primary_moomoo_account_id: nil) }
  # The rows whose Sure account is of `accountable_type` (see #sure_accountable).
  scope :set_up_as, ->(accountable_type) {
    case accountable_type
    when CASH_ACCOUNTABLE[:type] then where(role: "cash")
    when INVESTMENT_ACCOUNTABLE[:type] then where.not(role: "cash")
    else none
    end
  }

  def current_account
    account || linked_account
  end

  # Futures, crypto and moomoo Japan margin accounts are discovered but not
  # imported yet.
  def linkable?
    account_kind == "securities"
  end

  def ensure_account_provider!(account = nil)
    if account_provider.present?
      account_provider.update!(account: account) if account && account_provider.account_id != account.id
      return account_provider
    end

    acct = account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "MoomooAccount", provider_id: id)
      .tap do |record|
        record.account = acct
        record.save!
      end

    reload_account_provider
    provider
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "warn",
      message: "MoomooAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}",
      source: "moomoo",
      family: moomoo_item.family,
      provider_key: "moomoo"
    )
    nil
  end

  def currency_account?
    primary_moomoo_account_id.present?
  end

  # The row that holds moomoo's data for this trading account.
  def source_account
    primary_moomoo_account || self
  end

  # Whether this trading account is split into rows per currency, so this
  # row imports only its own currency's positions, fills and cash log rows.
  def split_by_currency?
    currency_account? || currency_accounts.any?
  end

  def cash_role?
    role == "cash"
  end

  def stocks_role?
    role == "stocks"
  end

  # The accountable type and subtype of the Sure account this row is set up
  # as, or may be linked to.
  def sure_accountable
    cash_role? ? CASH_ACCOUNTABLE : INVESTMENT_ACCOUNTABLE
  end

  # Every row of this trading account, the primary first.
  def trading_account_rows
    primary = source_account
    [ primary, *primary.currency_accounts ]
  end

  # The other rows of the same trading account.
  def sibling_currency_accounts
    trading_account_rows.reject { |row| row.id == id }
  end

  # The row whose Sure account takes a currency's trades and holdings.
  def trades_row_for(currency)
    trading_account_rows.find { |row| row.currency == currency && !row.cash_role? }
  end

  def cash_row_for(currency)
    trading_account_rows.find { |row| row.currency == currency && row.cash_role? }
  end

  # The row whose Sure account takes a currency's cash log rows: its cash
  # row, linked or not, so a stocks account never takes the cash log; or the
  # currency's combined row when it isn't split.
  def cash_log_row_for(currency)
    cash_row_for(currency) || trading_account_rows.find { |row| row.currency == currency && row.role == "combined" }
  end

  def takes_cash_logs?
    cash_log_row_for(currency)&.id == id
  end

  def positions
    return [] if cash_role?

    rows = Array(source_account.raw_positions_payload).select { |position| position.is_a?(Hash) }
    split_by_currency? ? rows.select { |position| position_currency(position) == currency } : rows
  end

  # The fills this row imports as trades.
  def fills
    cash_role? ? [] : currency_fills
  end

  # This row's currency's fills, which the cash row of a split account pays
  # for (see MoomooAccount::TradeSettlements).
  def currency_fills
    rows = Array(source_account.raw_fills_payload).select { |fill| fill.is_a?(Hash) && fill["deal_id"].present? }
    return rows unless split_by_currency?

    orders = source_account.orders_map
    by_code = source_account.positions_by_code
    rows.select { |fill| fill_currency(fill, orders, by_code) == currency }
  end

  def cash_log_rows
    return [] unless takes_cash_logs?

    rows = Array(source_account.raw_cash_logs_payload).select { |row| row.is_a?(Hash) }
    split_by_currency? ? rows.select { |row| cash_log_currency(row) == currency } : rows
  end

  # All positions of the trading account by code, which tell the security
  # type and currency of a fill whose order Sure hasn't seen.
  def positions_by_code
    Array(source_account.raw_positions_payload).select { |position| position.is_a?(Hash) }.index_by { |position| position["code"].to_s }
  end

  def trd_markets
    MoomooAccount::DataHelpers.trd_markets_for(source_account.enable_markets)
  end

  # Per trd_market: newest_us and oldest_us (the fetched span, in µs),
  # gap_from_us and gap_until_us (a part of it a later sync left for the
  # backfill), complete once the history reaches the backfill floor with no
  # gap, and failures, the syncs in a row its history failed to load.
  def history_cursor(market)
    (history_cursors || {}).fetch(market, {})
  end

  def update_history_cursor!(market, **values)
    with_lock do
      cursor = history_cursor(market).merge(values.transform_keys(&:to_s)).compact
      update!(history_cursors: (history_cursors || {}).merge(market => cursor))
    end
  end

  def history_backfill_pending?
    trd_markets.any? { |market| history_pending?(market) }
  end

  # The last sync that listed this account couldn't refresh its balance and
  # positions: moomoo refused them, or sent funds Sure can't use. It keeps
  # its last ones, and the trades it made since wait for the next snapshot:
  # holdings history is worked back from the newest snapshot, which would
  # count those trades twice.
  def snapshot_stale?
    source = source_account
    source.last_seen_at.present? && (source.last_positions_sync.nil? || source.last_positions_sync < source.last_seen_at)
  end

  def history_pending?(market)
    cursor = source_account.history_cursor(market)
    !cursor["complete"] && cursor["failures"].to_i < HISTORY_FAILURE_LIMIT
  end

  # Slim orders keyed by order_id.
  def orders_map
    raw_orders_payload.is_a?(Hash) ? raw_orders_payload : {}
  end

  def importable_positions
    positions.select { |position| importable_position?(position) }
  end
end
