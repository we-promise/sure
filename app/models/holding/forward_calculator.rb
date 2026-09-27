class Holding::ForwardCalculator
  include Holding::TradeCalculatorHelpers

  attr_reader :account

  # Track journal basis before the requested window and carry dated untraded snapshots.
  def initialize(account, security_ids: nil, window_start_date: nil)
    @account = account
    @security_ids = security_ids
    @window_start_date = window_start_date
    @carry_holdings = account.accounting_start_date.present?
    # Track weighted-average cost basis per security, relieving sells so the
    # figure stays correct after a position is fully sold and repurchased.
    @cost_basis_trackers = Hash.new { |h, k| h[k] = Holding::CostBasisTracker.new }
    # Securities whose position has taken in a transfer. A coin moved in was
    # acquired at a price nothing here knows, and averaging the purchases alone
    # would apply their price to units that never cost it.
    @transferred_security_ids = Set.new
  end

  # Seed earlier trades, then emit positions only inside the materialization window.
  def calculate
    Rails.logger.tagged("Holding::ForwardCalculator") do
      current_portfolio = generate_starting_portfolio
      next_portfolio = {}
      holdings = []

      first_date = @window_start_date || account.start_date
      portfolio_cache.get_trades.select { |entry| entry.date < first_date }.each do |entry|
        current_portfolio = apply_trades(current_portfolio, [ entry ])
      end

      first_date.upto(Date.current).each do |date|
        trades = portfolio_cache.get_trades(date: date)
        next_portfolio = apply_trades(current_portfolio, trades)
        holdings.concat(build_holdings(next_portfolio, date))
        holdings.concat(untraded_holdings(date)) if @carry_holdings
        current_portfolio = next_portfolio
      end

      Holding.gapfill(holdings)
    end
  end

  private
    # Allow known snapshot prices to support accounts using shared cash anchors.
    def portfolio_cache
      @portfolio_cache ||= Holding::PortfolioCache.new(account, security_ids: @security_ids,
        use_holdings: @carry_holdings, carry_forward_prices: @carry_holdings)
    end

    # Carry only snapshots already established on this date, preserving their
    # basis metadata while repricing; complete-provider omissions stay omitted.
    def untraded_holdings(date)
      @untraded_snapshots ||= begin
        traded_ids = account.trades.distinct.pluck(:security_id)
        scope = account.holdings.where.not(security_id: traded_ids).order(:date)
        scope = scope.where(security_id: @security_ids) if @security_ids
        @active_provider_security_ids = account.current_holdings.pluck(:security_id).to_set
        scope.to_a.group_by(&:security_id)
      end

      @untraded_snapshots.filter_map do |security_id, snapshots|
        index = snapshots.bsearch_index { |holding| holding.date > date }
        snapshot = index ? (snapshots[index - 1] if index.positive?) : snapshots.last
        next unless snapshot
        next if snapshot.account_provider_id && !@active_provider_security_ids.include?(security_id)

        price = portfolio_cache.get_price(security_id, date, currency: snapshot.currency)
        next unless price

        Holding::HoldingData.new(account_id: account.id, security_id: security_id, date: date,
          qty: snapshot.qty, price: price.price, currency: price.currency,
          amount: snapshot.qty * price.price, snapshot: snapshot)
      end
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
