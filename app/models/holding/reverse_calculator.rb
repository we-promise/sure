class Holding::ReverseCalculator
  include Holding::TradeCalculatorHelpers

  # Providers whose holdings are dated position by position rather than as one
  # portfolio. Plaid dates each holding by its own institution_price_as_of, so
  # one sync can write positions days apart, and its rows on a given date are
  # only the positions priced that day. Every other holdings processor writes
  # all of its positions on a single date: the sync date, or for IBKR the
  # statement's report date.
  PER_POSITION_DATED_PROVIDERS = %w[PlaidAccount].freeze

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
      # Start with the portfolio snapshot passed in from the materializer,
      # brought forward to today first (see #starting_portfolio).
      #
      # Every security a full snapshot has ever reported is in it, at zero if
      # the latest snapshot no longer has it. A position that is gone -- a
      # sold fund, a sweep fund that settled -- then gets zero rows after its
      # last snapshot, instead of Holding.gapfill carrying its last quantity
      # forward to today.
      #
      # The walk keeps each provider's quantities apart (see
      # #apply_provider_snapshots) and sums them per security for each day.
      portfolio = { nil => full_snapshot_security_ids.values.flat_map(&:to_a).to_h { |id| [ id, 0 ] }.merge(starting_portfolio) }

      holdings = []

      # The latest price seen for each security as the walk goes back in time,
      # for the dates nothing else can price (see #carry_price?).
      @carried_prices = latest_provider_prices

      Date.current.downto(account.start_date).each do |date|
        portfolio = apply_provider_snapshots(portfolio, date)

        # If current day, always use holding prices (since that's what Plaid gives us).  For historical values, use market data (since Plaid doesn't supply historical prices)
        holdings.concat(build_holdings(total_portfolio(portfolio), date, price_source: date == Date.current ? "holding" : nil))

        today_trades = portfolio_cache.get_trades(date: date)
        portfolio = portfolio.merge(nil => transform_portfolio(portfolio[nil], today_trades, direction: :reverse))
        portfolio = portfolio.transform_values { |quantities| undo_splits(quantities, date) }
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

    # A provider's holdings are what the account held at the close of their
    # date. Start that day from them, rather than from the positions carried
    # back from today, so the days before derive from them: a day between two
    # syncs takes the later one, not today's quantities.
    #
    # Only a provider that writes its whole portfolio on one date says what
    # is *not* held. Its securities missing from that date are at zero, the
    # same reading Holding::PortfolioSnapshot gives the latest snapshot. A
    # per-position provider's rows set the quantities they report and leave
    # every other security alone: its other positions are dated by their own
    # prices, not missing.
    #
    # `portfolio` is { account_provider_id => { security_id => qty } }. Each
    # provider sets only its own quantities, so an account linked to two
    # providers that both hold a security keeps the other provider's share
    # when one of them drops it. Under nil is what no provider snapshot has
    # set yet: the starting portfolio, and the trades undone since, which
    # carry no provider. A snapshot already includes the trades before it, so
    # a security it sets leaves nil there.
    def apply_provider_snapshots(portfolio, date)
      (provider_snapshots[date] || {}).each_with_object(portfolio.dup) do |(provider_id, positions), state|
        reported = full_snapshot_security_ids[provider_id]
        quantities = reported ? reported.to_h { |id| [ id, 0 ] }.merge(positions) : positions

        state[provider_id] = (state[provider_id] || {}).merge(quantities)
        state[nil] = state[nil].except(*quantities.keys)
      end
    end

    # { security_id => qty } summed over every provider's quantities.
    def total_portfolio(portfolio)
      portfolio.values.reduce({}) do |total, quantities|
        total.merge(quantities) { |_security_id, a, b| a + b }
      end
    end

    # { date => { account_provider_id => { security_id => qty } } } from the
    # provider-sourced holdings.
    def provider_snapshots
      @provider_snapshots ||= account.holdings
        .where.not(account_provider_id: nil)
        .pluck(:date, :account_provider_id, :security_id, :qty)
        .each_with_object({}) do |(date, provider_id, security_id, qty), snapshots|
          ((snapshots[date] ||= {})[provider_id] ||= {})[security_id] = qty
        end
    end

    # { account_provider_id => Set[security_id] }: every security each
    # full-snapshot provider has reported (see PER_POSITION_DATED_PROVIDERS).
    def full_snapshot_security_ids
      @full_snapshot_security_ids ||= begin
        full_snapshot_providers = account.account_providers
          .where.not(provider_type: PER_POSITION_DATED_PROVIDERS)
          .pluck(:id)
          .to_set

        provider_snapshots.values.each_with_object({}) do |by_provider, reported|
          by_provider.each do |provider_id, positions|
            next unless full_snapshot_providers.include?(provider_id)

            (reported[provider_id] ||= Set.new).merge(positions.keys)
          end
        end
      end
    end

    # The price on each security's most recent provider holding, in the
    # account's currency, to start the carry from. A holding with no exchange
    # rate to the account's currency has none.
    def latest_provider_prices
      latest_provider_holdings.each_with_object({}) do |(security_id, holding), prices|
        price = account_currency_price(holding.price, holding.currency, holding.date)
        next if price.nil?

        prices[security_id] = Security::Price.new(security_id: security_id, date: holding.date, price: price, currency: account.currency)
      end
    end

    # { security_id => the security's most recent provider holding }
    def latest_provider_holdings
      @latest_provider_holdings ||= account.holdings
        .where.not(account_provider_id: nil)
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

        price = portfolio_cache.get_price(security_id, date, source: price_source, converted_only: true)

        if price
          @carried_prices[security_id] = price
        elsif carry_price?(security_id, qty)
          price = carried_price(security_id, date)
        end

        # A price with no exchange rate to the account's currency is written
        # on its own date as Holding::PortfolioCache#get_price gives it,
        # unconverted, but never carried to another day.
        price ||= portfolio_cache.get_price(security_id, date, source: price_source)
        price ||= zero_quantity_price(security_id, date) if qty.zero?

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

      events.each do |event|
        if event.is_a?(Security::Split)
          security_id = event.security_id
          next unless positions.key?(security_id)

          positions[security_id] = Security::Split.scale(positions[security_id], event.ratio)
          trackers[security_id].split(event.ratio)
          @cost_basis_snapshots[security_id] << [ event.ex_date, trackers[security_id].average_cost ]
          next
        end

        trade_entry = event
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
            trackers[security_id].apply(effective_trade_price(trade, date: trade_entry.date), trade.qty)
            @cost_basis_snapshots[security_id] << [ trade_entry.date, trackers[security_id].average_cost ]
          end
        else
          tracker = trackers[security_id]
          # Buys raise the basis; sells relieve quantity at the running average, and a
          # full liquidation resets it so a later repurchase starts from a clean basis.
          tracker.apply(effective_trade_price(trade, date: trade_entry.date), trade.qty)

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

    # Trades and splits in the order they took effect. A split goes first on its
    # ex-date: it happens at the open, and that day's trades are already in
    # post-split shares. `trades` is chronological and kept in its own order.
    def replay_events(trades)
      events = trades.each_with_index.map { |entry, index| [ entry.date, 1, index, entry ] }
      events += portfolio_cache.get_splits.map { |split| [ split.ex_date, 0, 0, split ] }
      events.sort_by { |date, kind, index, _| [ date, kind, index ] }.map(&:last)
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
