class Holding::ReverseCalculator
  include Holding::TradeCalculatorHelpers

  # Providers whose older holdings are not read as snapshots. Plaid dates a
  # sync's rows by the newest price in the payload, not by the day the
  # quantities were observed, so an older Plaid row's date is not the date of
  # its count (see #4317). An older date of these providers sets nothing: no
  # security's count is reset there, and the trades alone carry the
  # provider's history back from its latest snapshot. That latest snapshot is
  # still the provider's whole portfolio, as Account#current_holdings reads
  # it, since #4317 writes every Plaid holding of a sync on one date. Their
  # older rows are still read as prices.
  LATEST_SNAPSHOT_ONLY_PROVIDERS = %w[PlaidAccount].freeze

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
      # Start with each provider's latest snapshot, or with no provider
      # holdings the portfolio snapshot passed in from the materializer,
      # brought forward to today first (see #starting_portfolio).
      #
      # Every security a provider has ever reported is in it, at zero if that
      # provider's latest snapshot no longer has it. A position that is gone
      # -- a sold fund, a sweep fund that settled -- then gets zero rows after
      # its last snapshot, instead of Holding.gapfill carrying its last
      # quantity forward to today.
      #
      # The walk keeps each provider's quantities apart (see
      # #apply_provider_snapshots) and sums them per security for each day.
      portfolio = starting_portfolio

      # Today's portfolio walked back through the trades and splits alone, as
      # #precompute_cost_basis replays them, for the days an older snapshot
      # holds what the trades do not explain (see #build_holdings). It is kept
      # by provider too, so each share rounds across a split as it does in
      # `portfolio`, and the two differ only where an older snapshot set a
      # quantity. A provider's latest snapshot is today's position, so both
      # walks take its reported count again on its date: brought to today
      # across a split and back, it can come out a digit off, and splits
      # before that date multiply the digit to the bound that marks a
      # quantity the trades do not explain.
      explained = portfolio

      holdings = []

      # The latest price seen for each security as the walk goes back in time,
      # for the dates nothing else can price (see #carry_price?).
      @carried_prices = latest_provider_prices

      Date.current.downto(account.start_date).each do |date|
        portfolio = apply_provider_snapshots(portfolio, date)
        explained = apply_provider_snapshots(explained, date, latest_only: true)

        # If current day, always use holding prices (since that's what Plaid gives us).  For historical values, use market data (since Plaid doesn't supply historical prices)
        holdings.concat(build_holdings(total_portfolio(portfolio), date, explained: total_portfolio(explained), price_source: date == Date.current ? "holding" : nil))

        today_trades = portfolio_cache.get_trades(date: date)
        portfolio = step_back(portfolio, today_trades, date)
        explained = step_back(explained, today_trades, date)
      end

      holdings
    end

    # From the close of `date` to the close of the day before: the day's
    # trades, which carry no provider, are undone, then its splits.
    def step_back(portfolio, trades, date)
      portfolio
        .merge(nil => transform_portfolio(portfolio[nil], trades, direction: :reverse))
        .transform_values { |quantities| undo_splits(quantities, date) }
    end

    # The portfolio as it stands today, kept by provider as the walk keeps it
    # (see #apply_provider_snapshots).
    #
    # Each provider starts from its own latest snapshot. Two providers rarely
    # sync on the same day, and starting both from the latest date across the
    # account left out the one that synced earlier: its shares were missing
    # from today and came back on its snapshot date, so the account held more
    # the day before than today with no trade in between. A provider's latest
    # snapshot is everything it holds, so a security it reported before and
    # not there is at zero for it.
    #
    # Under nil is what no provider reports: the securities known only from
    # trades, at zero. With no provider holdings at all it is the portfolio
    # snapshot passed in from the materializer.
    def starting_portfolio
      @starting_portfolio ||= begin
        by_provider = latest_provider_portfolios
        { nil => snapshot_portfolio.except(*by_provider.values.flat_map(&:keys)) }.merge(by_provider)
      end
    end

    # { account_provider_id => { security_id => qty } }: each provider's
    # latest snapshot, read as #apply_provider_snapshots reads it on its date,
    # brought forward to today.
    def latest_provider_portfolios
      latest_snapshot_dates.to_h do |provider_id, date|
        quantities = snapshot_quantities(provider_id, provider_snapshots[date][provider_id])

        [ provider_id, quantities.to_h { |security_id, qty| [ security_id, brought_to_today(security_id, qty, date) ] } ]
      end
    end

    # { account_provider_id => the date of its latest snapshot }
    def latest_snapshot_dates
      @latest_snapshot_dates ||= provider_snapshots.keys.sort.each_with_object({}) do |date, latest|
        provider_snapshots[date].each_key { |provider_id| latest[provider_id] = date }
      end
    end

    # The portfolio snapshot passed in, brought forward to today.
    def snapshot_portfolio
      # A snapshot that reports no dates is read as current, which is what this
      # did before there were any.
      dates = portfolio_snapshot.effective_dates || {}

      portfolio_snapshot.to_h.to_h do |security_id, qty|
        [ security_id, brought_to_today(security_id, qty, dates[security_id]) ]
      end
    end

    # A quantity observed at the close of `date`, as it stands today.
    #
    # The walk below starts at `Date.current` and undoes its way back, so it
    # reads a snapshot as today's position. A provider snapshot is often older
    # than that -- a sync that failed and retried late, or a provider that had
    # not refreshed -- and a split that went ex in between has already changed
    # the share count the provider reported. Left alone, today's holding kept
    # the pre-split quantity, and the walk then *undid* that same split on the
    # way past, so the history came out short as well.
    #
    # Each quantity is carried forward by the splits between the day it was
    # observed and today. Trades in that window are a separate, older gap: this
    # calculator has always assumed the snapshot already includes them, and
    # nothing here changes that.
    def brought_to_today(security_id, qty, date)
      factor = portfolio_cache.split_factor_between(security_id, date, Date.current)
      factor == 1 ? qty : Security::Split.scale(qty, factor)
    end

    # A provider's older holdings are what the account held at the close of
    # their date. Start that day from them, rather than from the positions
    # carried back from today, so the days before derive from them: a day
    # between two syncs takes the later one, not today's quantities. An older
    # date of a provider in LATEST_SNAPSHOT_ONLY_PROVIDERS sets nothing.
    #
    # A provider's latest snapshot is where its quantities start (see
    # #starting_portfolio), read as today's position: the trades dated after
    # it are already in it. Most providers date it the day they sync, but
    # Plaid dates it by its newest price while the quantities are as of the
    # sync, and a snapshot that has not refreshed since is still the latest
    # position known. Reaching its date sets the provider's quantities again,
    # at the count it reported rather than one scaled across splits and back,
    # and leaves the trades undone since in place.
    #
    # `portfolio` is { account_provider_id => { security_id => qty } }. Each
    # provider sets only its own quantities, so an account linked to two
    # providers that both hold a security keeps the other provider's share
    # when one of them drops it. Under nil is what no provider snapshot has
    # set: the securities known only from trades, and the trades undone
    # since, which carry no provider. An older snapshot already includes the
    # trades before it, so a security it sets leaves nil there.
    #
    # With `latest_only`, only a provider's latest snapshot is applied, as the
    # walk of the trades alone takes it (see #calculate_holdings).
    def apply_provider_snapshots(portfolio, date, latest_only: false)
      (provider_snapshots[date] || {}).each_with_object(portfolio.dup) do |(provider_id, positions), state|
        latest = date == latest_snapshot_dates[provider_id]
        next if !latest && (latest_only || latest_snapshot_only_provider_ids.include?(provider_id))

        quantities = snapshot_quantities(provider_id, positions)

        state[provider_id] = (state[provider_id] || {}).merge(quantities)
        state[nil] = state[nil].except(*quantities.keys) unless latest
      end
    end

    # The quantities a provider's positions on one date set. A snapshot is
    # the provider's whole portfolio, so it also says what is *not* held: the
    # securities it reported before that are missing from that date are at
    # zero, the same reading Holding::PortfolioSnapshot gives the latest
    # snapshot.
    def snapshot_quantities(provider_id, positions)
      reported_security_ids[provider_id].to_h { |id| [ id, 0 ] }.merge(positions)
    end

    def latest_snapshot_only_provider_ids
      @latest_snapshot_only_provider_ids ||= account.account_providers
        .where(provider_type: LATEST_SNAPSHOT_ONLY_PROVIDERS)
        .pluck(:id)
        .to_set
    end

    # { security_id => qty } summed over every provider's quantities.
    def total_portfolio(portfolio)
      portfolio.values.reduce({}) do |total, quantities|
        total.merge(quantities) { |_security_id, a, b| a + b }
      end
    end

    # { date => { account_provider_id => { security_id => qty } } } from the
    # provider-sourced holdings. A provider can have two rows for a security
    # on one date, in two currencies, as after a remap onto a security it
    # also reports, so its quantity is their sum.
    def provider_snapshots
      @provider_snapshots ||= account.holdings
        .where.not(account_provider_id: nil)
        .pluck(:date, :account_provider_id, :security_id, :qty)
        .each_with_object({}) do |(date, provider_id, security_id, qty), snapshots|
          positions = ((snapshots[date] ||= {})[provider_id] ||= {})
          positions[security_id] = (positions[security_id] || 0) + qty
        end
    end

    # { account_provider_id => Set[security_id] }: every security each
    # provider has reported.
    def reported_security_ids
      @reported_security_ids ||= provider_snapshots.values.each_with_object({}) do |by_provider, reported|
        by_provider.each do |provider_id, positions|
          (reported[provider_id] ||= Set.new).merge(positions.keys)
        end
      end
    end

    # The price on each security's most recent provider holding that holds
    # it and converts to the account's currency, to start the carry from. A
    # zero row marks a closed position and keeps whatever price that provider
    # last had, while another provider can still hold the security at its
    # own. A holding with no exchange rate to the account's currency has no
    # price to carry, so the next one down is tried: another provider's on the
    # same date, in another currency, else an older one.
    def latest_provider_prices
      provider_holdings = account.holdings.where.not(account_provider_id: nil).where.not(qty: 0)
      provider_holdings = provider_holdings.where(security_id: @security_ids.to_a) if @security_ids

      provider_holdings
        .order(date: :desc, id: :asc)
        .pluck(:security_id, :date, :price, :currency)
        .each_with_object({}) do |(security_id, date, amount, currency), prices|
          next if prices.key?(security_id)

          price = account_currency_price(amount, currency, date)
          next if price.nil?

          prices[security_id] = Security::Price.new(security_id: security_id, date: date, price: price, currency: account.currency)
        end
    end

    # { security_id => the security's most recent provider holding }
    def latest_provider_holdings
      @latest_provider_holdings ||= account.holdings.where.not(account_provider_id: nil)
        .select("DISTINCT ON (security_id) security_id, date, price, currency")
        .order(:security_id, date: :desc)
        .reject { |holding| @security_ids && !@security_ids.include?(holding.security_id) }
        .index_by(&:security_id)
    end

    # A zero quantity row only has to exist (see #carry_price?), so with no
    # price it can be given, it takes its provider's price unconverted: the
    # figure Holding::PortfolioCache#get_price falls back to, and worth
    # nothing at zero shares.
    def zero_quantity_price(security_id, date)
      holding = latest_provider_holdings[security_id]
      return unless holding

      Security::Price.new(security_id: security_id, date: date, price: holding.price, currency: account.currency)
    end

    # The conversion Holding::PortfolioCache#get_price applies, so a carried
    # price is in the same currency as every other price in the walk. Nil
    # without an exchange rate: the amount is not in the account's currency.
    def account_currency_price(amount, currency, date)
      Money.new(amount, currency).exchange_to(account.currency, date: date).amount
    rescue Money::ConversionError
      nil
    end

    # A security with no market data (offline) is priced only by its provider
    # holdings and trades, so on any other date it has no price and no row,
    # and before its first snapshot the account reads as if it never held it.
    # For those, the nearest later known price stands in. A security with
    # market data is left to it: a date it cannot price is a gap in that data,
    # not something to fill with a figure from another day.
    #
    # A zero quantity is worth nothing at any price, so it takes the carried
    # price whatever the security: the row only has to exist, to stop
    # Holding.gapfill from extending a position that has gone.
    def carry_price?(security_id, qty)
      qty.zero? || offline_security_ids.include?(security_id)
    end

    def offline_security_ids
      @offline_security_ids ||= portfolio_cache.get_securities.select(&:offline?).map(&:id).to_set
    end

    # The carried price as it applies on `date`. It is per share as of its own
    # date, and a split in between changed what one share is.
    def carried_price(security_id, date)
      carried = @carried_prices[security_id]
      return unless carried

      price = if date > carried.date
        factor = portfolio_cache.split_factor_between(security_id, carried.date, date)
        carried.price.to_d * factor.denominator / factor.numerator
      else
        factor = portfolio_cache.split_factor_between(security_id, date, carried.date)
        carried.price.to_d * factor.numerator / factor.denominator
      end

      Security::Price.new(security_id: security_id, date: date, price: price, currency: carried.currency)
    end

    # The day's own price, else, where #carry_price? allows, the carried one.
    #
    # Today reads holding prices first. A security with no holding today, as
    # when only a provider that synced earlier holds it, can still have a
    # quote for today, which comes before a price carried from another day
    # and before Holding.gapfill copying the day before.
    #
    # A price with no exchange rate to the account's currency is written on
    # its own date as Holding::PortfolioCache#get_price gives it, unconverted.
    # This calculator never carries it to another day, but Holding.gapfill
    # still copies that row onto the days after it that have no row of their
    # own, as it did before.
    def price_on(security_id, qty, date, price_source)
      carry = carry_price?(security_id, qty)
      sources = [ price_source, nil ].uniq

      sources.each do |source|
        price, converted = portfolio_cache.get_price_and_conversion(security_id, date, source: source)
        next unless price

        @carried_prices[security_id] = price if converted
        return price
      end

      carried_price(security_id, date) if carry
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

    # A quantity that differs from what the trades explain (`explained`) came
    # from an older snapshot: the trades say nothing of what its other shares
    # cost, or which of their lots the missing ones were, so its cost is
    # unknown that day.
    def build_holdings(portfolio, date, explained:, price_source: nil)
      portfolio.map do |security_id, qty|
        next if @security_ids && !@security_ids.include?(security_id)

        price = price_on(security_id, qty, date, price_source)
        price ||= zero_quantity_price(security_id, date) if qty.zero?

        if price.nil?
          next
        end

        unexplained = (qty - (explained[security_id] || 0)).abs >= Holding::LotBook::OPENING_RESIDUAL_BOUND

        Holding::HoldingData.new(
          account_id: account.id,
          security_id: security_id,
          date: date,
          qty: qty,
          price: price.price,
          currency: price.currency,
          amount: qty * price.price,
          cost_basis: unexplained ? nil : cost_basis_for(security_id, date),
          cost_basis_unknown: unexplained || transferred_by?(security_id, date) || @clamped_security_ids.include?(security_id)
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

      # get_trades is already in replay order (date, created_at, acquisitions
      # before disposals, then id).
      # Re-sorting by date alone is unstable and could reorder same-day trades,
      # which matters because the lot book is order-sensitive once sells relieve.
      trades = portfolio_cache.get_trades
      # A scheduled trade has not happened yet, so it explains none of today's
      # position.
      trades = trades.reject { |te| te.date > Date.current }
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
      # brought forward to today, as #calculate_holdings does, summed over the
      # providers.
      snapshot = total_portfolio(starting_portfolio)
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
    # nothing to open and is recorded as clamped. A shortfall within the drift a
    # split's rounding leaves (OPENING_RESIDUAL_BOUND) is not one: there is
    # nothing to open either, but the trades still explain the position.
    def open_lots(baselines, traded:)
      @clamped_security_ids = Set.new
      baselines.each do |security_id, qty|
        if qty < -Holding::LotBook::OPENING_RESIDUAL_BOUND && traded.include?(security_id)
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

    # [date, cost basis, whether the cost is unknown]: under fifo, whether an
    # open lot's cost is; under average, whether the pool took an unpriced buy.
    # A transfer-in leaves the average where it was, so its entry repeats the
    # last figure.
    def record_cost_basis(security_id, date)
      book = @lot_books[security_id]
      unknown = account.cost_basis_fifo? ? book.unknown_cost? : book.unpriced?
      @cost_basis_snapshots[security_id] << [ date, book.average_cost, unknown ]
    end

    # Under fifo a transfer-in or an unpriced buy stops mattering once its lot
    # is sold, so the book's own answer on the day counts; under average either
    # is unknown until the position closes.
    def transferred_by?(security_id, date)
      recorded = cost_basis_snapshot(security_id, date)&.last || false
      return recorded if account.cost_basis_fifo?

      recorded || @unknown_spans[security_id].any? { |start, stop| start <= date && (stop.nil? || date < stop) }
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
