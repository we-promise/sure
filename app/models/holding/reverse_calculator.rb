class Holding::ReverseCalculator
  include Holding::TradeCalculatorHelpers

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

        Holding::HoldingData.new(
          account_id: account.id,
          security_id: security_id,
          date: date,
          qty: qty,
          price: price.price,
          currency: price.currency,
          amount: qty * price.price,
          cost_basis: cost_basis_for(security_id, date),
          cost_basis_unknown: transferred_by?(security_id, date)
        )
      end.compact
    end

    def precompute_cost_basis
      @cost_basis_snapshots = Hash.new { |h, k| h[k] = [] }
      # Spans [start, end) during which a security still holds transferred-in units
      # of unknown cost. `end` is nil while a span is still open at the last trade.
      @unknown_spans = Hash.new { |h, k| h[k] = [] }
      trackers = Hash.new { |h, k| h[k] = Holding::CostBasisTracker.new }
      open_unknown_start = {}

      # get_trades is already chronological (date, then created_at, then id).
      # Re-sorting by date alone is unstable and could reorder same-day trades,
      # which matters because the tracker is order-sensitive once sells relieve.
      trades = portfolio_cache.get_trades

      # A reverse-synced account can hold shares before its first imported trade,
      # because the provider gives current holdings rather than full history. Seed
      # each running position from the snapshot minus the net imported trades, so
      # "position back at zero" reflects the real position, not just the trades we
      # happen to have.
      net_qty = Hash.new(0)
      trades.each { |te| net_qty[te.entryable.security_id] += te.entryable.qty }
      snapshot = portfolio_snapshot.to_h
      positions = Hash.new(0)
      net_qty.each_key { |security_id| positions[security_id] = (snapshot[security_id] || 0) - net_qty[security_id] }

      trades.each do |trade_entry|
        trade = trade_entry.entryable
        security_id = trade.security_id
        previous_position = positions[security_id]
        positions[security_id] += trade.qty

        if trade.internal_movement?
          # Inbound transfers make the basis unknown from that date on; outbound
          # transfers only remove units, so relieve them at the running average.
          if trade.qty.positive?
            open_unknown_start[security_id] ||= trade_entry.date
          else
            trackers[security_id].apply(converted_trade_price(trade, trade_entry.date), trade.qty)
            @cost_basis_snapshots[security_id] << [ trade_entry.date, trackers[security_id].average_cost ]
          end
        else
          tracker = trackers[security_id]
          # Buys raise the basis; sells relieve quantity at the running average, and a
          # full liquidation resets it so a later repurchase starts from a clean basis.
          tracker.apply(converted_trade_price(trade, trade_entry.date), trade.qty)

          # Record the basis after each trade — including nil once a position is fully
          # closed — so cost_basis_for returns nil for the sold-out span instead of a
          # stale figure carried forward from the last buy.
          @cost_basis_snapshots[security_id] << [ trade_entry.date, tracker.average_cost ]
        end

        # Close an open unknown span only on a genuine downward crossing through
        # zero. A position that was already non-positive — e.g. a gapped import
        # whose reconstructed baseline is negative — never held these units, so
        # opening and closing must not collapse onto the same trade.
        if open_unknown_start[security_id] && previous_position.positive? && positions[security_id] <= 0
          @unknown_spans[security_id] << [ open_unknown_start[security_id], trade_entry.date ]
          open_unknown_start.delete(security_id)
        end
      end

      # Spans still open at the last trade stay unknown through to the present.
      open_unknown_start.each { |security_id, start| @unknown_spans[security_id] << [ start, nil ] }
    end

    def transferred_by?(security_id, date)
      @unknown_spans[security_id].any? { |start, stop| start <= date && (stop.nil? || date < stop) }
    end

    def cost_basis_for(security_id, date)
      return nil if transferred_by?(security_id, date)

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
