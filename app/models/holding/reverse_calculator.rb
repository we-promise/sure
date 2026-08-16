class Holding::ReverseCalculator
  attr_reader :account, :portfolio_snapshot

  def initialize(account, portfolio_snapshot:, security_ids: nil)
    @account = account
    @portfolio_snapshot = portfolio_snapshot
    @security_ids = security_ids
  end

  def calculate
    Rails.logger.tagged("Holding::ReverseCalculator") do
      precompute_cost_basis
      holdings = calculate_holdings
      Holding.gapfill(holdings)
    end
  end

  private
    # Reverse calculators will use the existing holdings as a source of security ids and prices
    # since it is common for a provider to supply "current day" holdings but not all the historical
    # trades that make up those holdings.
    def portfolio_cache
      @portfolio_cache ||= Holding::PortfolioCache.new(account, use_holdings: true, security_ids: @security_ids)
    end

    def calculate_holdings
      # Start with the portfolio snapshot passed in from the materializer
      current_portfolio = portfolio_snapshot.to_h
      previous_portfolio = {}

      holdings = []

      Date.current.downto(account.start_date).each do |date|
        today_trades = portfolio_cache.get_trades(date: date)
        previous_portfolio = transform_portfolio(current_portfolio, today_trades, direction: :reverse)

        # If current day, always use holding prices (since that's what Plaid gives us).  For historical values, use market data (since Plaid doesn't supply historical prices)
        holdings.concat(build_holdings(current_portfolio, date, price_source: date == Date.current ? "holding" : nil))
        current_portfolio = previous_portfolio
      end

      holdings
    end

    def transform_portfolio(previous_portfolio, trade_entries, direction: :forward)
      new_quantities = previous_portfolio.dup

      trade_entries.each do |trade_entry|
        trade = trade_entry.entryable
        security_id = trade.security_id
        qty_change = trade.qty
        qty_change = qty_change * -1 if direction == :reverse
        new_quantities[security_id] = (new_quantities[security_id] || 0) + qty_change
      end

      new_quantities
    end

    def build_holdings(portfolio, date, price_source: nil)
      portfolio.map do |security_id, qty|
        next if @security_ids && !@security_ids.include?(security_id)

        price = portfolio_cache.get_price(security_id, date, source: price_source)

        if price.nil?
          next
        end

        Holding.new(
          account_id: account.id,
          security_id: security_id,
          date: date,
          qty: qty,
          price: price.price,
          currency: price.currency,
          amount: qty * price.price,
          cost_basis: cost_basis_for(security_id, date, price.currency)
        )
      end.compact
    end

    def precompute_cost_basis
      @cost_basis_buys = Hash.new { |h, k| h[k] = [] }
      # Snapshots keep binary search over buy dates; conversion stays currency-aware
      # and is memoized by [security_id, currency, buy_count].
      @cost_basis_snapshots = Hash.new { |h, k| h[k] = [] }
      @cost_basis_memo = {}
      @fx_rate_memo = {}

      portfolio_cache.get_trades.sort_by(&:date).each do |trade_entry|
        trade = trade_entry.entryable
        next unless trade.qty > 0

        security_id = trade.security_id
        @cost_basis_buys[security_id] << {
          date: trade_entry.date,
          qty: trade.qty,
          price: trade.price,
          currency: trade.currency
        }

        @cost_basis_snapshots[security_id] << [
          trade_entry.date,
          @cost_basis_buys[security_id].size
        ]
      end
    end

    def cost_basis_for(security_id, date, currency)
      buy_count = buy_count_as_of(security_id, date)
      return nil if buy_count.nil? || buy_count.zero?

      memo_key = [ security_id, currency, buy_count ]
      return @cost_basis_memo[memo_key] if @cost_basis_memo.key?(memo_key)

      applicable = @cost_basis_buys[security_id].first(buy_count)
      @cost_basis_memo[memo_key] = weighted_average_cost(applicable, currency)
    end

    def buy_count_as_of(security_id, date)
      snapshots = @cost_basis_snapshots[security_id]
      return nil if snapshots.empty?

      lo, hi, result = 0, snapshots.size - 1, nil
      while lo <= hi
        mid = (lo + hi) / 2
        if snapshots[mid][0] <= date
          result = snapshots[mid][1]
          lo = mid + 1
        else
          hi = mid - 1
        end
      end
      result
    end

    def weighted_average_cost(buys, currency)
      total_qty = buys.sum { |buy| buy[:qty] }
      return nil if total_qty.zero?

      total_cost = BigDecimal("0")

      buys.each do |buy|
        converted_price = convert_buy_price(buy, currency)
        return nil if converted_price.nil?

        total_cost += converted_price * buy[:qty]
      end

      total_cost / total_qty
    end

    def convert_buy_price(buy, currency)
      return buy[:price] if buy[:currency] == currency

      rate = fx_rate(from: buy[:currency], to: currency, date: buy[:date])
      # Match Money#exchange_to: absent or non-positive rates are unusable
      # (ExchangeRate does not enforce positivity at the DB layer).
      return nil unless rate&.positive?

      buy[:price] * rate
    end

    def fx_rate(from:, to:, date:)
      key = [ from, to, date ]
      return @fx_rate_memo[key] if @fx_rate_memo.key?(key)

      @fx_rate_memo[key] = ExchangeRate.find_or_fetch_rate(from: from, to: to, date: date)&.rate
    end
end
