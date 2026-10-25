class Holding::ReverseCalculator
  include Holding::TradeCalculatorHelpers

  attr_reader :account, :portfolio_snapshot

  def initialize(account, portfolio_snapshot:, security_ids: nil)
    @account = account
    @portfolio_snapshot = portfolio_snapshot
    @security_ids = security_ids
  end

  # Every lot of each security, the opening lot included, once #calculate has run.
  def lots_by_security
    lots_from(@lot_books)
  end

  # What each sale of each security took from which lot, once #calculate has run.
  def lot_disposals_by_security
    disposals_from(@lot_books)
  end

  # Securities whose provider quantity is below what their trades add up to.
  attr_reader :clamped_security_ids

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
      # Start with the portfolio snapshot passed in from the materializer,
      # brought forward to today first (see #starting_portfolio).
      current_portfolio = starting_portfolio
      previous_portfolio = {}

      holdings = []

      Date.current.downto(account.start_date).each do |date|
        today_trades = portfolio_cache.get_trades(date: date)
        previous_portfolio = undo_splits(transform_portfolio(current_portfolio, today_trades, direction: :reverse), date)

        # If current day, always use holding prices (since that's what Plaid gives us).  For historical values, use market data (since Plaid doesn't supply historical prices)
        holdings.concat(build_holdings(current_portfolio, date, price_source: date == Date.current ? "holding" : nil))
        current_portfolio = previous_portfolio
      end

      holdings
    end

    # The snapshot as it stands today.
    #
    # The walk below starts at `Date.current` and undoes its way back, so it
    # reads the snapshot as today's position. A provider snapshot is often
    # older than that -- a sync that failed and retried late, or a provider
    # that had not refreshed -- and a split that went ex in between has already
    # changed the share count the provider reported. Left alone, today's
    # holding kept the pre-split quantity, and the walk then *undid* that same
    # split on the way past, so the history came out short as well.
    #
    # Each quantity is carried forward by the splits between the day it was
    # observed and today. Trades in that window are a separate, older gap: this
    # calculator has always assumed the snapshot already includes them, and
    # nothing here changes that.
    def starting_portfolio
      # A snapshot that reports no dates is read as current, which is what this
      # did before there were any.
      @starting_portfolio ||= begin
        dates = portfolio_snapshot.effective_dates || {}

        portfolio_snapshot.to_h.to_h do |security_id, qty|
          factor = portfolio_cache.split_factor_between(security_id, dates[security_id], Date.current)
          next [ security_id, qty ] if factor == 1

          [ security_id, Security::Split.scale(qty, factor) ]
        end
      end
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

    # Walking back from the close of `date` to the close of the day before: once
    # the day's trades are undone, a split that went ex on `date` is undone too,
    # since it took effect at that day's open (#249).
    def undo_splits(portfolio, date)
      portfolio.to_h do |security_id, qty|
        ratio = portfolio_cache.get_split_ratio(security_id, date)
        [ security_id, ratio ? Security::Split.unscale(qty, ratio) : qty ]
      end
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
          cost_basis_unknown: transferred_by?(security_id, date) || @clamped_security_ids.include?(security_id)
        )
      end.compact
    end

    def precompute_cost_basis
      @cost_basis_snapshots = Hash.new { |h, k| h[k] = [] }
      # Spans [start, end) during which a security still holds transferred-in units
      # of unknown cost. `end` is nil while a span is still open at the last trade.
      @unknown_spans = Hash.new { |h, k| h[k] = [] }
      @lot_books = Hash.new { |h, k| h[k] = Holding::LotBook.new(method: account.cost_basis_method) }
      open_unknown_start = {}

      # get_trades is already chronological (date, then created_at, then id).
      # Re-sorting by date alone is unstable and could reorder same-day trades,
      # which matters because the lot book is order-sensitive once sells relieve.
      trades = portfolio_cache.get_trades
      # A scoped run (a remap, a price sync) replays only its own securities;
      # the cache holds every trade in the account.
      trades = trades.select { |te| @security_ids.include?(te.entryable.security_id) } if @security_ids
      events = replay_events(trades)

      # A reverse-synced account can hold shares before its first imported trade,
      # because the provider gives current holdings rather than full history. Seed
      # each running position by walking the snapshot back through every imported
      # trade and split, so "position back at zero" reflects the real position,
      # not just the trades we happen to have. Across a split, "snapshot minus
      # net trades" is not that: the trades before it are in pre-split shares.
      # The walk undoes every split up to today, so it starts from the snapshot
      # brought forward to today, as #calculate_holdings does.
      snapshot = starting_portfolio
      positions = Hash.new(0)
      trades.each { |te| positions[te.entryable.security_id] = snapshot[te.entryable.security_id] || 0 }
      events.reverse_each do |event|
        if event.is_a?(Security::Split)
          next unless positions.key?(event.security_id)

          positions[event.security_id] = Security::Split.unscale(positions[event.security_id], event.ratio)
        else
          positions[event.entryable.security_id] -= event.entryable.qty
        end
      end
      # The snapshot covers the whole account; a scoped run books only its own.
      baselines = snapshot.merge(positions)
      baselines = baselines.slice(*@security_ids) if @security_ids
      open_lots(baselines, traded: positions.keys)

      events.each do |event|
        if event.is_a?(Security::Split)
          security_id = event.security_id
          next unless positions.key?(security_id)

          positions[security_id] = Security::Split.scale(positions[security_id], event.ratio)
          @lot_books[security_id].split(event.ratio)
          record_cost_basis(security_id, event.ex_date)
          next
        end

        trade_entry = event
        trade = trade_entry.entryable
        security_id = trade.security_id
        previous_position = positions[security_id]
        positions[security_id] += trade.qty
        manual_cost = manual_unit_cost(trade_entry)

        if trade.internal_movement? && manual_cost.nil?
          # Inbound transfers make the basis unknown from that date on, unless
          # the user has said what the lot cost; outbound transfers only remove
          # units, so relieve them at the running average.
          if trade.qty.positive?
            open_unknown_start[security_id] ||= trade_entry.date
            @lot_books[security_id].add_unknown(trade.qty, source_id: trade_entry.id, acquired_on: trade_entry.date)
          else
            @lot_books[security_id].apply(effective_trade_price(trade, date: trade_entry.date), trade.qty)
          end
          record_cost_basis(security_id, trade_entry.date)
        else
          book = @lot_books[security_id]
          # Buys raise the basis; sells relieve quantity at the running average, and a
          # full liquidation resets it so a later repurchase starts from a clean basis.
          price = manual_cost || effective_trade_price(trade, date: trade_entry.date)
          book.apply(price, trade.qty, source_id: trade_entry.id, acquired_on: trade_entry.date,
            lot_source_id: trade.lot_source_entry_id)

          # Record the basis after each trade — including nil once a position is fully
          # closed — so cost_basis_for returns nil for the sold-out span instead of a
          # stale figure carried forward from the last buy.
          record_cost_basis(security_id, trade_entry.date)
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

      # Splitting the snapshot back and forward again rounds; the opening lot
      # takes it (or the last open lot, once sold), so the lots add up to the
      # provider's quantity.
      snapshot.each do |security_id, qty|
        next unless @lot_books.key?(security_id)

        @lot_books[security_id].settle_opening(qty, bound: Holding::LotBook::OPENING_RESIDUAL_BOUND)
      end
    end

    # Units held before the first imported trade (or, with no trades, all the
    # provider reports) are the opening lot. Its cost is unknown to the trades,
    # so it stays out of the average, and sales relieve it like any other lot.
    # A traded position whose provider quantity is below its trades' total has
    # nothing to open and is recorded as clamped.
    def open_lots(baselines, traded:)
      @clamped_security_ids = Set.new
      baselines.each do |security_id, qty|
        if qty.negative? && traded.include?(security_id)
          @clamped_security_ids << security_id
        else
          @lot_books[security_id].add_unknown(qty)
        end
      end
    end

    # Trades and splits in the order they took effect. A split goes first on its
    # ex-date: it happens at the open, and that day's trades are already in
    # post-split shares. `trades` is chronological and kept in its own order.
    def replay_events(trades)
      events = trades.each_with_index.map { |entry, index| [ entry.date, 1, index, entry ] }
      events += portfolio_cache.get_splits.map { |split| [ split.ex_date, 0, 0, split ] }
      events.sort_by { |date, kind, index, _| [ date, kind, index ] }.map(&:last)
    end

    # [date, cost basis, whether an open lot's cost is unknown]. A transfer-in
    # leaves the average where it was, so its entry repeats the last figure.
    def record_cost_basis(security_id, date)
      book = @lot_books[security_id]
      @cost_basis_snapshots[security_id] << [ date, book.average_cost, account.cost_basis_fifo? && book.unknown_cost? ]
    end

    # Under fifo a transfer-in stops mattering once its lot is sold, so the
    # book's own answer on the day counts; under average it is unknown until
    # the position closes.
    def transferred_by?(security_id, date)
      return cost_basis_snapshot(security_id, date)&.last || false if account.cost_basis_fifo?

      @unknown_spans[security_id].any? { |start, stop| start <= date && (stop.nil? || date < stop) }
    end

    # A clamped position holds fewer units than its trades bought, so no
    # figure drawn from those trades is the position's.
    def cost_basis_for(security_id, date)
      return nil if transferred_by?(security_id, date) || @clamped_security_ids.include?(security_id)

      cost_basis_snapshot(security_id, date)&.second
    end

    # The last entry on or before `date`.
    def cost_basis_snapshot(security_id, date)
      snapshots = @cost_basis_snapshots[security_id]
      lo, hi, result = 0, snapshots.size - 1, nil
      while lo <= hi
        mid = (lo + hi) / 2
        if snapshots[mid][0] <= date
          result = snapshots[mid]
          lo = mid + 1
        else
          hi = mid - 1
        end
      end
      result
    end
end
