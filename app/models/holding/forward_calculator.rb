class Holding::ForwardCalculator
  include Holding::TradeCalculatorHelpers

  attr_reader :account

  def initialize(account, security_ids: nil)
    @account = account
    @security_ids = security_ids
    # Track weighted-average cost basis per security, relieving sells so the
    # figure stays correct after a position is fully sold and repurchased.
    @cost_basis_trackers = Hash.new { |h, k| h[k] = Holding::CostBasisTracker.new }
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
        holdings.concat(build_holdings(next_portfolio, date))
        current_portfolio = next_portfolio
      end

      Holding.gapfill(holdings)
    end
  end

  private
    def portfolio_cache
      @portfolio_cache ||= Holding::PortfolioCache.new(account, security_ids: @security_ids)
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
          cost_basis: cost_basis_for(security_id, price.currency)
        )
      end.compact
    end

    # Applies each trade to its security's weighted-average cost basis tracker.
    # Buys raise the basis; sells relieve quantity at the running average and a
    # full liquidation resets it, so a later repurchase starts from a clean basis.
    def update_cost_basis_tracker(trade_entries)
      trade_entries.each do |trade_entry|
        trade = trade_entry.entryable
        @cost_basis_trackers[trade.security_id].apply(converted_trade_price(trade), trade.qty)
      end
    end

    # Returns the current cost basis for a security, or nil if nothing is held.
    def cost_basis_for(security_id, currency)
      @cost_basis_trackers[security_id].average_cost
    end
end
