class Holding::ForwardCalculator
  include Holding::TradeCalculatorHelpers

  attr_reader :account

  # Track journal basis before the requested window and carry dated untraded snapshots.
  def initialize(account, security_ids: nil, window_start_date: nil)
    @account = account
    @security_ids = security_ids
    @window_start_date = window_start_date
    @carry_holdings = account.accounting_start_date.present?
    # The lots of each security, which also give the weighted-average cost
    # basis, relieving sells so the figure stays correct after a position is
    # fully sold and repurchased.
    @lot_books = Hash.new { |h, k| h[k] = Holding::LotBook.new(method: account.cost_basis_method) }
    # Securities whose position has taken in a transfer. A coin moved in was
    # acquired at a price nothing here knows, and averaging the purchases alone
    # would apply their price to units that never cost it.
    @transferred_security_ids = Set.new
  end

  # Every lot of each security, once #calculate has run.
  def lots_by_security
    lots_from(@lot_books)
  end

  # What each sale of each security took from which lot, once #calculate has run.
  def lot_disposals_by_security
    disposals_from(@lot_books)
  end

  def clamped_security_ids
    Set.new
  end

  # Seed earlier trades, then emit positions only inside the materialization window.
  def calculate
    Rails.logger.tagged("Holding::ForwardCalculator") do
      current_portfolio = generate_starting_portfolio
      next_portfolio = {}
      holdings = []

      first_date = @window_start_date || account.start_date
      today = Date.current
      # Seed lots through the day before the window without applying scheduled trades early.
      account.start_date.upto([ first_date - 1, today ].min) do |date|
        current_portfolio = apply_trades(apply_splits(current_portfolio, date), portfolio_cache.get_trades(date: date))
      end

      first_date.upto(today).each do |date|
        trades = portfolio_cache.get_trades(date: date)
        next_portfolio = apply_trades(apply_splits(current_portfolio, date), trades)
        holdings.concat(build_holdings(next_portfolio, date))
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

    # An observation supplies its own day's position. Between observations,
    # carry their quantities only until the journal first moves shares.
    def snapshot_for(security_id, date)
      snapshots = portfolio_cache.get_holdings(security_id)
      return unless snapshots

      index = snapshots.bsearch_index { |holding| holding.date > date } || snapshots.length
      return if index.zero?

      snapshot = snapshots[index - 1]
      return snapshot if snapshot.date == date

      @first_trade_dates ||= portfolio_cache.get_trades.each_with_object({}) do |entry, dates|
        next if entry.entryable.qty.zero?

        dates[entry.entryable.security_id] ||= entry.date
      end
      first_trade_date = @first_trade_dates[security_id]
      return if first_trade_date && first_trade_date <= date

      snapshot
    end

    def build_snapshot_holding(snapshot, date)
      security_id = snapshot.security_id
      split_factor = portfolio_cache.split_factor_between(security_id, snapshot.date, date)
      price = portfolio_cache.get_price(security_id, date, currency: snapshot.currency)&.price ||
        Security::Split.unscale(snapshot.price, split_factor)
      qty = Security::Split.scale(snapshot.qty, split_factor)
      basis = Security::Split.unscale(snapshot.cost_basis, split_factor) if snapshot.cost_basis
      Holding::HoldingData.new(account_id: account.id, security_id: security_id, date: date,
        qty: qty, price: price, currency: snapshot.currency, amount: qty * price, cost_basis: basis, snapshot: snapshot)
    end

    def empty_portfolio
      securities = portfolio_cache.get_securities
      securities.each_with_object({}) { |security, hash| hash[security.id] = 0 }
    end

    def generate_starting_portfolio
      empty_portfolio
    end


    def build_holdings(portfolio, date, price_source: nil)
      portfolio.filter_map do |security_id, qty|
        next if @security_ids && !@security_ids.include?(security_id)

        snapshot = snapshot_for(security_id, date) if @carry_holdings
        next build_snapshot_holding(snapshot, date) if snapshot

        price = portfolio_cache.get_price(security_id, date, source: price_source)
        next unless price

        Holding::HoldingData.new(
          account_id: account.id,
          security_id: security_id,
          date: date,
          qty: qty,
          price: price.price,
          currency: price.currency,
          amount: qty * price.price,
          cost_basis: cost_basis_for(security_id, price.currency),
          cost_basis_unknown: cost_unknown?(security_id)
        )
      end
    end

    # A split takes effect at the open of its ex-date, before that day's trades,
    # which are already in post-split shares (#249). It scales the position and
    # its lot book together, so total cost carries across unchanged.
    def apply_splits(opening_portfolio, date)
      opening_portfolio.to_h do |security_id, qty|
        ratio = portfolio_cache.get_split_ratio(security_id, date)
        next [ security_id, qty ] unless ratio

        @lot_books[security_id].split(ratio)
        [ security_id, Security::Split.scale(qty, ratio) ]
      end
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
        manual_cost = manual_unit_cost(trade_entry)

        if trade.internal_movement? && manual_cost.nil?
          # An inbound transfer brings in units at a price nothing here knows, so
          # it makes the whole position's cost basis unknowable, unless the user
          # has said what its lot cost. An outbound transfer only removes units,
          # so relieve them at the running average (like a sell) rather than
          # leaving them to contaminate a later buy.
          if trade.qty.positive?
            @transferred_security_ids << security_id
            @lot_books[security_id].add_unknown(trade.qty, source_id: trade_entry.id, acquired_on: trade_entry.date)
          else
            @lot_books[security_id].apply(effective_trade_price(trade, date: trade_entry.date), trade.qty)
          end
        else
          price = manual_cost || effective_trade_price(trade, date: trade_entry.date)
          @lot_books[security_id].apply(price, trade.qty, source_id: trade_entry.id, acquired_on: trade_entry.date,
            lot_source_id: trade.lot_source_entry_id)
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
      return nil if cost_unknown?(security_id)

      @lot_books[security_id].average_cost
    end

    # Under fifo a transfer-in or an unpriced buy stops mattering once its lot
    # is sold, so the book answers; under average either is unknown until the
    # position closes.
    def cost_unknown?(security_id)
      return @lot_books[security_id].unknown_cost? if account.cost_basis_fifo?

      @transferred_security_ids.include?(security_id) || @lot_books[security_id].unpriced?
    end
end
