class Holding::PortfolioCache
  attr_reader :account, :use_holdings

  # Labels under which a trade at no price adds or moves units that nobody
  # observed to be worth nothing: an internal movement, a stock dividend, a
  # reinvestment, shares bought or paid in kind. Any other trade at no price
  # (Other, which providers book splits as; Exchange, a corporate action;
  # Sell; or no label) might be a split or a real zero, so its zero stays a
  # price (see #price_unpriced_trade_days).
  UNPRICED_SHARE_LABELS = (Trade::INTERNAL_MOVEMENT_LABELS + %w[Buy Dividend Reinvestment Interest Fee Contribution Withdrawal]).freeze
  # Labels a trade at no price can carry when it is a split booked as a trade.
  SPLIT_LIKE_LABELS = [ nil, "Other" ].freeze

  class SecurityNotFound < StandardError
    def initialize(security_id, account_id)
      super("Security id=#{security_id} not found in portfolio cache for account #{account_id}.  This should not happen unless securities were preloaded incorrectly.")
    end
  end

  # carry_forward_prices lets a cash-anchored account value a day without a quote at the last known one.
  def initialize(account, use_holdings: false, security_ids: nil, carry_forward_prices: false)
    @account = account
    @use_holdings = use_holdings
    @security_ids = security_ids
    @carry_forward_prices = carry_forward_prices
    load_prices
  end

  def get_trades(date: nil)
    if date.blank?
      trades
    else
      trades_by_date[date]&.dup || []
    end
  end

  # Resolve a dated quote with shared precedence and convert it to the requested currency.
  def get_price(security_id, date, source: nil, currency: account.currency)
    security = @security_cache[security_id]
    raise SecurityNotFound.new(security_id, account.id) unless security

    price_with_priority = if source.present?
      security[:prices_by_date_and_source][[ date, source ]]
    else
      security[:prices_by_date][date]
    end

    if price_with_priority.nil? && @carry_forward_prices && source.nil?
      dates = security[:price_dates]
      index = dates.bsearch_index { |value| value > date }
      previous_date = index ? (dates[index - 1] if index.positive?) : dates.last
      price_with_priority = security[:prices_by_date][previous_date] if previous_date
      # A quote carried across a split is for a pre-split share.
      carried_split = split_factor_between(security_id, previous_date, date)
    end

    return nil unless price_with_priority

    price = price_with_priority.price
    return nil unless price

    price_money = Money.new(carried_split ? Security::Split.unscale(price.price, carried_split) : price.price, price.currency)

    begin
      converted_amount = price_money.exchange_to(currency, date: date).amount
    rescue Money::ConversionError
      # Anchored accounts keep the last valued holding (gapfill) instead of
      # booking an unconverted quote or failing the whole sync.
      return nil if @carry_forward_prices

      converted_amount = price.price
    end

    Security::Price.new(
      security_id: security_id,
      date: price.date,
      price: converted_amount,
      currency: currency
    )
  end

  def get_securities
    @security_cache.map { |_, v| v[:security] }
  end

  def get_holdings(security_id)
    holdings_by_security_id[security_id]
  end

  # The ratio of the split a security goes ex on this date, or nil when it
  # has none. Nil, not 1, so a caller can leave an unsplit position untouched.
  def get_split_ratio(security_id, date)
    split_ratios[[ security_id, date ]]
  end

  # Every split within the account's history, oldest first.
  def get_splits
    splits
  end

  # How many shares one share held at the close of `from` has become by the
  # close of `to`: the product of the ratios of the splits in between. 1 when
  # there are none, so a caller can multiply unconditionally.
  #
  # Reads every split up to today, not only those within the account's
  # history: a provider snapshot can be older than the account's first entry
  # (an account with no entries starts yesterday), and a split between the
  # snapshot and that start still changed the count it reported.
  def split_factor_between(security_id, from, to)
    return Rational(1) if from.nil? || to.nil? || from >= to

    splits_through_today.reduce(Rational(1)) do |factor, split|
      next factor unless split.security_id == security_id
      next factor unless split.ex_date > from && split.ex_date <= to

      factor * split.ratio
    end
  end

  private
    PriceWithPriority = Data.define(:price, :priority, :source)

    # Only splits the holdings can see: from the account's start date, when
    # its holdings begin, to today. A split announced for a future ex-date is
    # not applied early; it takes effect when that date arrives.
    def splits
      @splits ||= Security::Split
        .where(security_id: @security_cache.keys, ex_date: account.start_date..Date.current)
        .order(:ex_date)
        .to_a
    end

    # Every split up to today, however early, for carrying a snapshot forward.
    def splits_through_today
      @splits_through_today ||= Security::Split
        .where(security_id: @security_cache.keys, ex_date: ..Date.current)
        .order(:ex_date)
        .to_a
    end

    def split_ratios
      @split_ratios ||= splits.to_h { |split| [ [ split.security_id, split.ex_date ], split.ratio ] }
    end

    # Entry.chronological, except that trades sharing a date and created_at, as
    # a batch import stamps them, replay acquisitions before disposals: their
    # ids say nothing about which came first, and a sale cannot precede the
    # purchase it sells from. Rows with different created_at keep their order.
    def trades
      @trades ||= chronological_trades
        .sort_by.with_index { |entry, index| [ entry.date, entry.created_at, entry.entryable.qty.negative? ? 1 : 0, index ] }
    end

    def chronological_trades
      @chronological_trades ||= account.entries.includes(entryable: :security).trades.chronological.to_a
    end

    def trades_by_date
      @trades_by_date ||= trades.group_by(&:date)
    end

    def trades_by_security_id
      # Which trade's price stands for a day must not depend on the replay order.
      @trades_by_security_id ||= chronological_trades.group_by { |t| t.entryable.security_id }
    end

    def holdings
      @holdings ||= begin
        scope = account.holdings
        # Rebuild anchored prices from observations so a corrected split can change them.
        if @carry_forward_prices
          scope = scope.where(security_id: @security_ids) if @security_ids
          scope.where(materialized: false).preferred_on_date.to_a
        else
          scope.where(superseded: false).chronological.to_a
        end
      end
    end

    def holdings_by_security_id
      @holdings_by_security_id ||= holdings.group_by(&:security_id)
    end

    def collect_unique_securities
      ids = trades_by_security_id.keys
      ids |= holdings_by_security_id.keys if use_holdings
      ids &= @security_ids if @security_ids

      Security.where(id: ids).to_a
    end

    # Loads all known prices for all securities in the account with priority based on source:
    # 1 - DB or provider prices
    # 2 - Trade prices
    # 3 - Holding prices
    #
    # A trade booked at no price that moves or adds units (a share journal, a
    # stock-plan deposit, a stock dividend) says nothing about what they were
    # worth. Taken as that day's price, its zero would value the whole
    # position at nothing until the next priced day, which without market data
    # can be months. Such a day takes the nearest real price instead (see
    # #price_unpriced_trade_days).
    def load_prices
      @security_cache = {}
      unpriced_trades_by_security_id = {}
      securities = collect_unique_securities

      Rails.logger.info "Preloading #{securities.size} securities for account #{account.id}"

      security_ids = securities.map(&:id)

      # Bulk-load all DB prices for all securities in one query, grouped by security_id
      db_prices_by_security_id = Security::Price
        .where(security_id: security_ids, date: account.start_date..Date.current)
        .group_by(&:security_id)

      securities.each do |security|
        Rails.logger.info "Loading security: ID=#{security.id} Ticker=#{security.ticker}"

        # High priority prices from DB (synced from provider)
        db_prices = (db_prices_by_security_id[security.id] || []).map do |price|
          PriceWithPriority.new(
            price: price,
            priority: 1,
            source: "db"
          )
        end

        # Medium priority prices from trades
        # Exclude income entries (interest/dividend) — they are non-trading
        # events with qty=0 and their zero price would clobber the security's
        # market price on that date in the ForwardCalculator, producing a
        # zero-amount holding.  Use qty (the same heuristic as
        # Balance::BaseCalculator) rather than price to avoid blocking
        # non-income zero-price trades such as Questrade journal transfers.
        unpriced_trades, priced_trades = (trades_by_security_id[security.id] || [])
          .reject { |t| t.entryable.qty == 0 }
          .partition { |t| unpriced_trade?(t.entryable) }
        unpriced_trades_by_security_id[security.id] = unpriced_trades if unpriced_trades.any?
        unpriced_dates = unpriced_trades.map(&:date).to_set

        # A trade at no price that might be a split stays a barrier to the
        # nearest-price search even on a day another price outranks it (see
        # #nearest_known_price). Only an unlabelled or "Other" trade might be
        # one: a sale or an exchange at no price leaves the shares as they
        # were, so that day's quote is in the same shares.
        barrier_dates = priced_trades
          .select { |t| !t.entryable.price&.positive? && SPLIT_LIKE_LABELS.include?(t.entryable.investment_activity_label) }
          .map(&:date).to_set

        trade_prices = priced_trades
          .map do |trade|
            PriceWithPriority.new(
              price: Security::Price.new(
                security: security,
                price: trade.entryable.price,
                currency: trade.entryable.currency,
                date: trade.date
              ),
              priority: 2,
              source: "trade"
            )
          end
        # On a day that might be a split, the first priced trade, which the
        # trade at no price can win a tie against (see #price_unpriced_trade_days)
        priced_trade_on_barrier = trade_prices
          .select { |p| barrier_dates.include?(p.price.date) && p.price.price.positive? }
          .group_by { |p| p.price.date }.transform_values(&:first)

        # Provider rows first, so a provider snapshot wins a day it shares with a
        # calculated row (in another currency, before the calculated one is
        # cleaned up) where both rank the same
        # A provider row with no units marks a position closed, not a price
        # (some providers write one at no price), so it is left out.
        security_holdings = if use_holdings
          (holdings_by_security_id[security.id] || [])
            .reject { |h| h.account_provider_id && h.qty.to_d.zero? }
            .sort_by { |h| h.account_provider_id ? 0 : 1 }
        else
          []
        end
        # Days whose holding price is only a calculated row's, which an earlier
        # sync derived from the prices known then
        calculated_holding_dates = security_holdings.select { |h| h.account_provider_id.nil? }.map(&:date).to_set -
          security_holdings.select(&:account_provider_id).map(&:date).to_set
        # Days from the first trade at no price on: their calculated rows were
        # filled in from prices as an earlier sync worked them out, the
        # movement's included, and anything seen since (a quote between two
        # runs, even today's) may change them. They give way like the movement
        # day's own, so the prices known now carry forward instead.
        first_unpriced = unpriced_dates.min
        carried_dates = if first_unpriced
          security_holdings.select { |h| h.account_provider_id.nil? && h.date > first_unpriced }.map(&:date).to_set
        else
          Set.new
        end
        passed_over = ->(h) { h.account_provider_id.nil? && (!h.price.positive? || unpriced_dates.include?(h.date) || carried_dates.include?(h.date)) }
        # The calculated rows passed over below (see #reprice_holding_source)
        passed_over_holdings = security_holdings.select(&passed_over)

        # Low priority prices from holdings (if applicable). A calculated row at
        # no price is skipped: its zero came from such a trade on an earlier
        # sync, and reading it back would keep the position at zero for good.
        # So is a calculated row on the day of a trade at no price, or on a day
        # after it up to the next price seen: its price was filled in on an
        # earlier sync from the prices known then, and is worked out again from
        # the prices known now.
        holding_prices = if use_holdings
          security_holdings.filter_map do |holding|
            next if passed_over.call(holding)

            PriceWithPriority.new(
              price: Security::Price.new(
                security: security,
                price: holding.price,
                currency: holding.currency,
                date: holding.date
              ),
              priority: 3,
              source: "holding"
            )
          end
        else
          []
        end

        all_prices = db_prices + trade_prices + holding_prices

        # Index by date for O(1) lookup in get_price instead of O(N) linear scan
        prices_by_date = all_prices.group_by { |p| p.price.date }
          .transform_values { |ps| ps.min_by(&:priority) }
        prices_by_date_and_source = all_prices.group_by { |p| [ p.price.date, p.source ] }
          .transform_values { |ps| ps.min_by(&:priority) }

        @security_cache[security.id] = {
          security: security,
          prices_by_date: prices_by_date,
          prices_by_date_and_source: prices_by_date_and_source,
          barrier_dates: barrier_dates,
          priced_trade_on_barrier: priced_trade_on_barrier,
          calculated_holding_dates: calculated_holding_dates,
          passed_over_holdings: passed_over_holdings,
          carried_dates: carried_dates
        }
      end

      # After the loop: the split lookup reads every security in the cache.
      earlier = latest_db_prices_before(account.start_date, unpriced_trades_by_security_id.keys)
      unpriced_trades_by_security_id.each do |security_id, trades|
        price_unpriced_trade_days(security_id, trades, earlier: earlier[security_id])
      end
      @security_cache.each do |security_id, cached|
        cached[:price_dates] = cached[:prices_by_date].keys.sort if @carry_forward_prices
        reprice_holding_source(security_id)
      end
    end

    # A lookup for holding prices alone (the reverse calculator reads today's
    # that way) still finds a day whose calculated row was passed over: it
    # finds the day's price as worked out on this sync; on a day after a trade
    # at no price, the latest one before it, which that trade's day carries
    # forward; otherwise, where the day has none, the row's own, as before.
    def reprice_holding_source(security_id)
      cached = @security_cache[security_id]
      known_dates = nil
      cached[:passed_over_holdings].each do |holding|
        key = [ holding.date, "holding" ]
        next if cached[:prices_by_date_and_source].key?(key)

        price = cached[:prices_by_date][holding.date]&.price
        if price.nil? && cached[:carried_dates].include?(holding.date)
          known_dates ||= cached[:prices_by_date].keys.sort
          index = known_dates.bsearch_index { |d| d >= holding.date } || known_dates.size
          if index.positive?
            carried = cached[:prices_by_date][known_dates[index - 1]].price
            # Carried across any split in between, as the rows themselves are
            factor = price_split_factor(security_id, carried.date, holding.date)
            amount = factor == 1 ? carried.price : Security::Split.unscale(carried.price, factor)
            price = Security::Price.new(security: cached[:security], price: amount, currency: carried.currency, date: holding.date)
          end
        end
        price ||= Security::Price.new(security: cached[:security], price: holding.price, currency: holding.currency, date: holding.date)
        cached[:prices_by_date_and_source][key] = PriceWithPriority.new(price: price, priority: 3, source: "holding")
      end
    end

    def unpriced_trade?(trade)
      !trade.price&.positive? && UNPRICED_SHARE_LABELS.include?(trade.investment_activity_label)
    end

    # A day whose only price would have been an unpriced trade's takes the
    # nearest price the security has: the latest before it, else the earliest
    # after it, carried across any recorded split in between. A zero found
    # there is taken rather than passed over: a position the provider prices
    # at nothing is worthless, and a split booked as a trade at no price
    # leaves the prices beyond it in other shares, by a ratio nothing here
    # knows. The day keeps a price, so the calculators still give it a holding
    # with the moved quantity. A security with no price at all keeps the
    # trade's zero.
    def price_unpriced_trade_days(security_id, trades, earlier: nil)
      cached = @security_cache[security_id]
      prices_by_date = cached[:prices_by_date]
      unpriced_days = trades.group_by(&:date).reject { |date, _| prices_by_date.key?(date) }
      return if unpriced_days.empty?

      # Observed prices only, zeros included: the unpriced trades' own and
      # calculated rows' zeros were never loaded, so any zero here was
      # observed. A calculated row's price is passed over too: an earlier sync
      # derived it from the prices known then, and a quote that has arrived
      # since must be able to replace it. So is the zero of a trade that might
      # be a split on a day a split is recorded: the recorded ratio carries the
      # prices on either side across it. The latest stored price
      # before the account's history is the nearest earlier one for a
      # trade on its first days.
      # A provider snapshot can be dated before that stored price, so the
      # list is sorted again; on the same date the stored price ranks first.
      # A priced trade the passed-over zero tied with on its day, else a
      # provider snapshot it outranked, takes the day instead.
      candidates = prices_by_date.each_with_object({}) do |(date, entry), kept|
        next if entry.source == "holding" && cached[:calculated_holding_dates].include?(date)

        if entry.source == "trade" && !entry.price.price.positive? && cached[:barrier_dates].include?(date) && split_recorded_on?(security_id, date)
          provider = cached[:prices_by_date_and_source][[ date, "holding" ]]
          provider = nil if cached[:calculated_holding_dates].include?(date)
          replacement = cached[:priced_trade_on_barrier][date] || provider
          kept[date] = replacement if replacement
        else
          kept[date] = entry
        end
      end
      if earlier
        stored = PriceWithPriority.new(price: earlier, priority: 1, source: "db")
        candidates[earlier.date] = stored if candidates[earlier.date].nil? || candidates[earlier.date].priority > stored.priority
      end
      known = candidates.sort_by(&:first)

      unpriced_days.each do |date, day_trades|
        filled = nearest_known_price(cached[:security], known, date, barrier_dates: cached[:barrier_dates]) ||
          PriceWithPriority.new(
            price: Security::Price.new(security: cached[:security], price: 0, currency: day_trades.first.entryable.currency, date: date),
            priority: 2,
            source: "trade"
          )
        prices_by_date[date] = filled
        # Indexed by its source too, as a lookup for one source reads it there
        cached[:prices_by_date_and_source][[ date, filled.source ]] ||= filled
      end
    end

    # Like #split_factor_between, but over every recorded split, future ones
    # included: a future-dated trade's price is in the shares after a split
    # before it, even one that has not taken effect yet.
    def price_split_factor(security_id, from, to)
      return Rational(1) if from >= to

      all_splits.reduce(Rational(1)) do |factor, split|
        next factor unless split.security_id == security_id
        next factor unless split.ex_date > from && split.ex_date <= to

        factor * split.ratio
      end
    end

    def all_splits
      @all_splits ||= Security::Split.where(security_id: @security_cache.keys).order(:ex_date).to_a
    end

    def split_recorded_on?(security_id, date)
      all_splits.any? { |split| split.security_id == security_id && split.ex_date == date }
    end

    # The latest stored price of each security before `date`.
    def latest_db_prices_before(date, security_ids)
      return {} if security_ids.empty?

      Security::Price.where(security_id: security_ids).where(date: ...date)
        .select("DISTINCT ON (security_id) security_prices.*")
        .order(:security_id, date: :desc)
        .index_by(&:security_id)
    end

    # The nearest price before `date`, else after it, scaled across the splits
    # in between. Looking forward, a day holding a trade at no price that might
    # be a split is taken as zero even when another price outranks it there:
    # that price can be in the shares after the split, by a ratio nothing here
    # knows. A split recorded on that day gives the ratio, so the price is
    # scaled across it instead.
    def nearest_known_price(security, known, date, barrier_dates: Set.new)
      later_index = known.bsearch_index { |known_date, _| known_date > date } || known.size

      if later_index.positive?
        known_date, nearest = known[later_index - 1]
        factor = price_split_factor(security.id, known_date, date)
        amount = factor == 1 ? nearest.price.price : Security::Split.unscale(nearest.price.price, factor)
      elsif known.any?
        known_date, nearest = known.first
        factor = price_split_factor(security.id, date, known_date)
        amount = if barrier_dates.include?(known_date) && !split_recorded_on?(security.id, known_date)
          0
        else
          factor == 1 ? nearest.price.price : Security::Split.scale(nearest.price.price, factor)
        end
      else
        return nil
      end

      PriceWithPriority.new(
        price: Security::Price.new(security: security, price: amount, currency: nearest.price.currency, date: date),
        priority: nearest.priority,
        source: nearest.source
      )
    end
end
