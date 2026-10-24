# frozen_string_literal: true

# Lists the security trades (buys/sells) recorded on the user's investment and
# crypto accounts, newest first, with optional filters by account, security,
# side and date range.
#
# Read-only companion to CreateTrade: same scoping (accounts the user can
# access), same underlying Trade rows the app's account activity feed shows.
class Assistant::Function::GetTrades < Assistant::Function
  SUPPORTED_SIDES = %w[buy sell].freeze

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
        investment and crypto accounts, newest first. Use it to answer "what did
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
    def trades_scope
      Trade.visible.where(entries: { account_id: accessible_accounts.select(:id) })
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

      trades = trades.where(qty: ...0) if side == "sell"
      trades = trades.where(qty: 0...) if side == "buy"

      if start_date || end_date
        range = start_date..end_date
        trades = trades.where(entries: { date: range })
      end

      trades
    end

    def serialize(trade)
      entry = trade.entry

      {
        id: trade.id,
        date: entry.date,
        name: entry.name,
        side: trade.qty.to_d.negative? ? "sell" : "buy",
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
