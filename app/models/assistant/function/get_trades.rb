# frozen_string_literal: true

# Lists the security trades (buys and sells) recorded on the user's investment
# and crypto accounts, newest first, with optional filters by account, security,
# side and date range.
#
# Dividends, interest, fees, sweeps, reinvestments and other cash or internal
# movements live in the same table. They are excluded here: a buy or sell is a
# row labeled Buy or Sell, or an unlabeled legacy row with a nonzero quantity.
# Read-only companion to CreateTrade, scoped to accounts the user can access.
class Assistant::Function::GetTrades < Assistant::Function
  SUPPORTED_SIDES = %w[buy sell].freeze
  BUY_SELL_LABELS = %w[Buy Sell].freeze

  class << self
    # The tool's stable name; this is the MCP function identifier callers use.
    def name
      "get_trades"
    end

    def default_page_size
      25
    end

    # Human/LLM-facing description of what the tool does and how to call it.
    def description
      <<~INSTRUCTIONS
        Returns the security trades (buys and sells) recorded on the user's
        investment and crypto accounts, newest first. Dividends, interest, fees,
        sweeps and reinvestments are not included. Use it to answer "what did
        I buy/sell", to review activity for a period, or to check a position's
        trade history before suggesting a change.

        Every filter is optional and combines with AND:

          - `accounts`: account names from the example below
          - `securities`: ticker symbols already traded in the family
          - `side`: "buy" or "sell"
          - `start_date` / `end_date`: inclusive ISO 8601 dates (YYYY-MM-DD)

        Results are paginated; `page` is required and `page_size` is fixed at
        #{default_page_size} results per page. A page beyond the last one is
        clamped to the last page (the response's `page` tells you which page was
        actually returned).

        Example (all trades):

        ```
        get_trades({
          page: 1
        })
        ```

        Example (buys of one security in a period):

        ```
        get_trades({
          page: 1,
          securities: ["AAPL"],
          side: "buy",
          start_date: "2026-01-01",
          end_date: "2026-10-10"
        })
        ```
      INSTRUCTIONS
    end
  end

  # Not strict: the tool validates its own inputs and returns structured error
  # hashes instead of raising.
  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "page" ],
      properties: {
        page: {
          type: "integer",
          minimum: 1,
          description: "Page number"
        },
        accounts: {
          type: "array",
          description: "Filter by account name (only Investment and Crypto accounts hold trades)",
          items: { enum: investment_account_names },
          minItems: 1,
          uniqueItems: true
        },
        securities: {
          type: "array",
          description: "Filter by security ticker symbol",
          items: { enum: family_trade_tickers },
          minItems: 1,
          uniqueItems: true
        },
        side: {
          type: "string",
          enum: SUPPORTED_SIDES,
          description: "Filter by trade side"
        },
        start_date: {
          type: "string",
          description: "Inclusive start date (YYYY-MM-DD)"
        },
        end_date: {
          type: "string",
          description: "Inclusive end date (YYYY-MM-DD)"
        }
      }
    )
  end

  def call(params = {})
    start_date = parse_date(params["start_date"])
    return error("invalid_date", "start_date must be an ISO 8601 date (YYYY-MM-DD).") if params["start_date"].present? && start_date.nil?

    end_date = parse_date(params["end_date"])
    return error("invalid_date", "end_date must be an ISO 8601 date (YYYY-MM-DD).") if params["end_date"].present? && end_date.nil?

    side = params["side"].to_s.strip.downcase.presence
    return error("invalid_side", "side must be one of #{SUPPORTED_SIDES.join(', ')}.") if side && !SUPPORTED_SIDES.include?(side)

    trades_query = filtered_trades(params, start_date, end_date, side)
    ordered_trades = trades_query.reverse_chronological

    pagy = Pagy.new(count: ordered_trades.count, page: resolved_page(params), limit: default_page_size)
    paginated_trades = ordered_trades.includes(:security, entry: :account).offset(pagy.offset).limit(pagy.limit)

    {
      trades: paginated_trades.map { |trade| serialize(trade) },
      total_results: pagy.count,
      page: pagy.page,
      page_size: default_page_size,
      total_pages: pagy.pages
    }
  end

  private
    def default_page_size
      self.class.default_page_size
    end

    def accessible_accounts
      user.accessible_accounts.visible.where(accountable_type: %w[Investment Crypto])
    end

    # Scoped to accounts the user can access (owned or shared), not the whole
    # family, mirroring GetHoldings. Trade is an Entryable, so the account lives
    # on the entry (trades has no entry_id column) — `visible` already joins it.
    #
    # Quantity sign is not enough. A dividend, interest payment or fee is stored
    # with qty 0, and a sweep or reinvestment has a nonzero qty, so both would
    # otherwise be reported as an ordinary buy or sell.
    def trades_scope
      Trade.visible
        .where(entries: { account_id: accessible_accounts.select(:id) })
        .where(genuine_buy_sell_sql, BUY_SELL_LABELS)
    end

    # Labeled buys and sells, plus unlabeled rows from before activity labels
    # existed. Those legacy rows are buys or sells only when the quantity is
    # nonzero; a zero quantity with no label is cash activity, not a trade.
    def genuine_buy_sell_sql
      <<~SQL.squish
        trades.investment_activity_label IN (?)
        OR (trades.investment_activity_label IS NULL AND trades.qty <> 0)
      SQL
    end

    def filtered_trades(params, start_date, end_date, side)
      trades = trades_scope

      if params["accounts"].present?
        account_ids = accessible_accounts.where(name: Array(params["accounts"])).select(:id)
        trades = trades.where(entries: { account_id: account_ids })
      end

      if params["securities"].present?
        security_ids = Security.where(ticker: Array(params["securities"])).select(:id)
        trades = trades.where(security_id: security_ids)
      end

      trades = filter_by_side(trades, side) if side

      if start_date || end_date
        range = start_date..end_date
        trades = trades.where(entries: { date: range })
      end

      trades
    end

    # Side follows the activity label. Quantity sign is only the fallback for
    # an unlabeled legacy row, and it never classifies a dividend or a sweep.
    def filter_by_side(trades, side)
      if side == "sell"
        trades.where(
          "trades.investment_activity_label = ? OR (trades.investment_activity_label IS NULL AND trades.qty < 0)",
          "Sell"
        )
      else
        trades.where(
          "trades.investment_activity_label = ? OR (trades.investment_activity_label IS NULL AND trades.qty > 0)",
          "Buy"
        )
      end
    end

    def trade_side(trade)
      return "buy" if trade.investment_activity_label == "Buy"
      return "sell" if trade.investment_activity_label == "Sell"

      trade.qty.to_d.negative? ? "sell" : "buy"
    end

    def serialize(trade)
      entry = trade.entry

      {
        id: trade.id,
        date: entry.date,
        name: entry.name,
        side: trade_side(trade),
        qty: trade.qty.to_d.abs.to_f,
        price: trade.price.to_d.to_f,
        fee: trade.fee.to_d.to_f,
        amount: format_money(entry),
        currency: entry.currency,
        account: entry.account.name,
        security: trade.security && {
          id: trade.security_id,
          ticker: trade.security.ticker,
          name: trade.security.name
        }
      }
    end

    def investment_account_names
      @investment_account_names ||= accessible_accounts.pluck(:name)
    end

    def family_trade_tickers
      @family_trade_tickers ||= Security
        .where(id: trades_scope.select(:security_id))
        .distinct
        .pluck(:ticker)
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def format_money(entry)
      entry.amount_money.format
    rescue StandardError
      "#{entry.amount} #{entry.currency}"
    end

    def error(key, message, extras = {})
      { success: false, error: key, message: message }.merge(extras)
    end
end
