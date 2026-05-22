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
          cost_basis: cost_basis_for(security_id, date)
        )
      end.compact
    end

    def precompute_cost_basis
      @cost_basis_snapshots = Hash.new { |h, k| h[k] = [] }
      tracker = Hash.new { |h, k| h[k] = { total_cost: BigDecimal("0"), total_qty: BigDecimal("0") } }

      portfolio_cache.get_trades.sort_by(&:date).each do |trade_entry|
        trade = trade_entry.entryable
        next unless trade.qty > 0

        security_id = trade.security_id
        trade_price = Money.new(trade.price, trade.currency)
        begin
          converted_price = trade_price.exchange_to(account.currency).amount
        rescue Money::ConversionError
          converted_price = trade.price
        end

        tracker[security_id][:total_cost] += converted_price * trade.qty
        tracker[security_id][:total_qty] += trade.qty

        @cost_basis_snapshots[security_id] << [
          trade_entry.date,
          tracker[security_id][:total_cost] / tracker[security_id][:total_qty]
        ]
      end
    end

    def cost_basis_for(security_id, date)
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
end
