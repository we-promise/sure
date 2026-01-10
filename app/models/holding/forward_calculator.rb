class Holding::ForwardCalculator
  attr_reader :account

  def initialize(account)
    @account = account
    # Track cost basis per security: { security_id => { total_cost: BigDecimal, total_qty: BigDecimal } }
    @cost_basis_tracker = Hash.new { |h, k| h[k] = { total_cost: BigDecimal("0"), total_qty: BigDecimal("0") } }
  end

  def calculate
    Rails.logger.tagged("Holding::ForwardCalculator") do
      current_portfolio = generate_starting_portfolio
      next_portfolio = {}
      holdings = []

      account.start_date.upto(Date.current).each do |date|
        trades = portfolio_cache.get_trades(date: date)
        update_cost_basis_tracker(trades)
        next_portfolio = transform_portfolio(current_portfolio, trades, direction: :forward)
        holdings += build_holdings(next_portfolio, date)
        current_portfolio = next_portfolio
      end

      Holding.gapfill(holdings)
    end
  end

  private
    def portfolio_cache
      @portfolio_cache ||= Holding::PortfolioCache.new(account)
    end

    def empty_portfolio
      securities = portfolio_cache.get_securities
      securities.each_with_object({}) { |security, hash| hash[security.id] = 0 }
    end

    def generate_starting_portfolio
      empty_portfolio
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
          cost_basis: cost_basis_for(security_id, price.currency)
        )
      end.compact
    end

    # Updates cost basis tracker with buy trades (qty > 0)
    # Uses weighted average cost method
    def update_cost_basis_tracker(trade_entries)
      trade_entries.each do |trade_entry|
        trade = trade_entry.entryable
        next unless trade.qty > 0 # Only track buys

        security_id = trade.security_id
        tracker = @cost_basis_tracker[security_id]

        # Convert trade price to account currency if needed
        trade_price = Money.new(trade.price, trade.currency)
        converted_price = trade_price.exchange_to(account.currency, fallback_rate: 1).amount

        tracker[:total_cost] += converted_price * trade.qty
        tracker[:total_qty] += trade.qty
      end
    end

    # Returns the current cost basis for a security, or nil if no buys recorded
    def cost_basis_for(security_id, currency)
      tracker = @cost_basis_tracker[security_id]
      return nil if tracker[:total_qty].zero?

      tracker[:total_cost] / tracker[:total_qty]
    end
end
