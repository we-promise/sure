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
        next_portfolio = apply_trades(current_portfolio, trades)
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

    # Applies the day's trades in order and returns the resulting portfolio, so the
    # caller does not walk the same trades again to compute quantities.
    #
    # Buys raise a security's weighted-average cost basis; sells relieve quantity at
    # the running average and a full liquidation resets it, so a later repurchase
    # starts from a clean basis. Tracking the running position here lets an inbound
    # transfer's "unknown" mark release the moment the position hits zero — even when
    # a same-day sell-off and repurchase net back to a positive end-of-day quantity.
    def apply_trades(opening_portfolio, trade_entries)
      portfolio = opening_portfolio.dup

      trade_entries.each do |trade_entry|
        trade = trade_entry.entryable
        security_id = trade.security_id
        previous_quantity = portfolio[security_id] || 0

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

        portfolio[security_id] = previous_quantity + trade.qty

        # Release the "unknown" mark only on a genuine downward crossing through
        # zero: a position that was already non-positive never held these units, so
        # opening and closing must not collapse onto the same trade.
        @transferred_security_ids.delete(security_id) if previous_quantity.positive? && portfolio[security_id] <= 0
      end

      portfolio
    end

    # Returns the current cost basis for a security, or nil if nothing is held
    # or the position contains transferred-in units of unknown cost.
    def cost_basis_for(security_id, currency)
      return nil if @transferred_security_ids.include?(security_id)

      @cost_basis_trackers[security_id].average_cost
    end
end
