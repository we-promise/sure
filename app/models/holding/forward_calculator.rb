class Holding::ForwardCalculator
  include Holding::TradeCalculatorHelpers

  attr_reader :account

  def initialize(account, security_ids: nil)
    @account = account
    @security_ids = security_ids
    # Track weighted-average cost basis per security, relieving sells so the
    # figure stays correct after a position is fully sold and repurchased.
    @cost_basis_trackers = Hash.new { |h, k| h[k] = Holding::CostBasisTracker.new }
    # Securities whose position has taken in a transfer. A coin moved in was
    # acquired at a price nothing here knows, and averaging the purchases alone
    # would apply their price to units that never cost it.
    @transferred_security_ids = Set.new
  end

  def calculate
    Rails.logger.tagged("Holding::ForwardCalculator") do
      current_portfolio = generate_starting_portfolio
      next_portfolio = {}
      holdings = []

      account.start_date.upto(Date.current).each do |date|
        trades = portfolio_cache.get_trades(date: date)
        update_cost_basis_tracker(trades, current_portfolio)
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

        Holding::HoldingData.new(
          account_id: account.id,
          security_id: security_id,
          date: date,
          qty: qty,
          price: price.price,
          currency: price.currency,
          amount: qty * price.price,
          cost_basis: cost_basis_for(security_id, price.currency),
          cost_basis_unknown: @transferred_security_ids.include?(security_id)
        )
      end.compact
    end

    # Applies each trade to its security's weighted-average cost-basis tracker.
    # Buys raise the basis; sells relieve quantity at the running average and a
    # full liquidation resets it, so a later repurchase starts from a clean basis.
    #
    # Trades are applied in order and the running position is tracked from the
    # day's opening quantities, so an inbound transfer's "unknown" mark is released
    # the moment the position hits zero — even when a same-day sell-off and
    # repurchase net back to a positive end-of-day quantity.
    def update_cost_basis_tracker(trade_entries, opening_portfolio)
      running_quantities = Hash.new { |h, k| h[k] = opening_portfolio[k] || 0 }

      trade_entries.each do |trade_entry|
        trade = trade_entry.entryable
        security_id = trade.security_id

        if trade.internal_movement?
          # An inbound transfer brings in units at a price nothing here knows, so
          # it makes the whole position's cost basis unknowable. An outbound
          # transfer only removes units, so relieve them at the running average
          # (like a sell) rather than leaving them to contaminate a later buy.
          if trade.qty.positive?
            @transferred_security_ids << security_id
          else
            @cost_basis_trackers[security_id].apply(converted_trade_price(trade), trade.qty)
          end
        else
          @cost_basis_trackers[security_id].apply(converted_trade_price(trade), trade.qty)
        end

        # A position back at zero holds no transferred-in units any more, so the
        # "unknown" mark is released and a later repurchase reads as known again.
        running_quantities[security_id] += trade.qty
        @transferred_security_ids.delete(security_id) if running_quantities[security_id] <= 0
      end
    end

    # Returns the current cost basis for a security, or nil if nothing is held
    # or the position contains transferred-in units of unknown cost.
    def cost_basis_for(security_id, currency)
      return nil if @transferred_security_ids.include?(security_id)

      @cost_basis_trackers[security_id].average_cost
    end
end
