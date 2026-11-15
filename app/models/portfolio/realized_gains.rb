# Realised profit and loss over time: what a set of investment accounts
# actually crystallised, and in which month.
#
# This is not a return figure. A return answers "how did the money perform";
# this answers "what was realised, and when".
#
# Four rules, each taken from code that already applies it:
#
# 1. A transfer out is not a sale. Both carry a negative `qty`, so a bare
#    `qty < 0` filter books the market value of a position the user moved
#    between their own accounts as a realised gain. Trade::
#    INTERNAL_MOVEMENT_LABELS lists the labels that preserve ownership, and it
#    is deliberately narrower than Transaction's: "Exchange" on a security can
#    dispose of an appreciated asset, so it stays in.
#
# 2. A realised gain is fixed on the day of the sale, so it converts into the
#    target currency at that day's rate (see below), never today's. Marking an
#    old disposal to today's rate restates a figure the user may already have
#    reported.
#    The figure is the gain in the holding's own currency, converted at the
#    sale date's rate: the foreign-exchange move on the cost while the
#    position was held is not part of it, so it is not a home-currency cost
#    basis gain and can differ from a tax figure computed that way.
#
# 3. A missing rate is not a rate of 1. ExchangeRate.rates_for ends in
#    `rate&.rate || 1`, so it hands back parity for a pair it could not find
#    and the caller cannot tell the two apart. Rates are read directly here,
#    and a disposal that cannot be converted is reported in #excluded_trades.
#
# 4. A disposal with no measurable gain is not a zero gain.
#    Trade#realized_gain_loss returns nil when the cost basis is unknown or
#    the proceeds cannot be converted into the basis currency; folding that to
#    0 drags a total toward zero with no sign that anything is missing. Those
#    disposals are excluded and counted.
#
# A disposal is a sell trade on an entry that is not excluded: an excluded
# entry is left out of reports, as InvestmentStatement::Totals and the
# Reports card's realised list leave it out. The gain is the one
# Trade#realized_gain_loss gives, against the holding's average cost at the
# time of the sale, not a FIFO or specific-lot basis.
#
# A sale's rate is the one stored for its date, else the nearest earlier one
# up to ExchangeRate::Provided::NEAREST_RATE_LOOKBACK_DAYS before it, the
# window ExchangeRate.find_or_fetch_rate reuses a stored rate from. Never a
# later day's, and never older than that window: a disposal with no rate
# inside it is reported in #excluded_trades.
class Portfolio::RealizedGains
  # One calendar month of realised activity. `losses` is a positive
  # magnitude; `net` carries the sign.
  Bucket = Data.define(:month, :gains, :losses, :trade_count) do
    def net
      gains - losses
    end
  end

  # Why a disposal could not be measured, in a stable order.
  #
  # - gain_unknown: Trade#realized_gain_loss returned nil -- no cost basis at
  #   or before the sale, or no rate to convert the proceeds into the basis.
  # - missing_exchange_rate: the gain is known, but there is no rate on or
  #   shortly before the sale date to convert it into the target currency.
  EXCLUSION_REASONS = %i[gain_unknown missing_exchange_rate].freeze

  attr_reader :accounts, :period, :currency, :active_until_dates

  # `active_until_dates` is `{ account_id => last_active_date }` for disabled
  # accounts, the shape Balance::ChartSeriesBuilder takes as
  # `account_active_until_dates`: a disposal after that date does not count.
  # Values may be anything with `to_date` (a Date or an ISO string): the
  # builder accepts both, as it hands them to SQL as JSON.
  def initialize(accounts:, period:, currency:, active_until_dates: {})
    @accounts = Array(accounts)
    @period = period
    @currency = currency
    @active_until_dates = (active_until_dates || {}).compact.transform_keys(&:to_s).transform_values(&:to_date)
  end

  # Months with realised activity, oldest first. A month with no disposals is
  # absent rather than a zero: an empty month and a break-even month are
  # different facts.
  def buckets
    @buckets ||= measured_rows
      .group_by { |row| row[:date].beginning_of_month }
      .sort_by(&:first)
      .map { |month, rows| build_bucket(month, rows) }
  end

  def total_gains
    @total_gains ||= buckets.sum(BigDecimal(0), &:gains)
  end

  def total_losses
    @total_losses ||= buckets.sum(BigDecimal(0), &:losses)
  end

  def net
    total_gains - total_losses
  end

  def trade_count
    @trade_count ||= buckets.sum(0, &:trade_count)
  end

  # `{ gain_unknown: n, missing_exchange_rate: n }`, omitting reasons with no
  # trades, so a total that leaves disposals out can say so.
  def excluded_trades
    @excluded_trades ||= begin
      counts = exclusions.tally
      EXCLUSION_REASONS.filter_map { |reason| [ reason, counts[reason] ] if counts[reason] }.to_h
    end
  end

  def excluded_trade_count
    exclusions.size
  end

  # True when there is anything to report, excluded disposals included: a
  # period whose every disposal was unmeasurable has no buckets, and that is
  # exactly the case a caller must not hide.
  def any?
    buckets.any? || excluded_trade_count.positive?
  end

  private
    def build_bucket(month, rows)
      Bucket.new(
        month: month,
        gains: rows.sum(BigDecimal(0)) { |row| row[:amount].positive? ? row[:amount] : BigDecimal(0) },
        losses: rows.sum(BigDecimal(0)) { |row| row[:amount].negative? ? -row[:amount] : BigDecimal(0) },
        trade_count: rows.size
      )
    end

    def measured_rows
      measure!
      @measured_rows
    end

    def exclusions
      measure!
      @exclusions
    end

    # Each measurable disposal as `{ date:, amount: }` in `currency`, and a
    # reason for each one that is not. Computed once, because the same pass
    # decides both.
    def measure!
      return if defined?(@measured_rows)

      # Built in locals and assigned last: if sell_trades or target_rates
      # raises, defined?(@measured_rows) must stay false so the next read
      # retries instead of trusting a half-memoized empty pass.
      rows = []
      exclusions = []

      gains = sell_trades.map { |trade| [ trade, trade.realized_gain_loss ] }
      rates = target_rates(gains)

      gains.each do |trade, gain|
        # Rule 4. Not a zero gain.
        next exclusions << :gain_unknown if gain.nil?

        # The gain is Money in the basis currency (the holding's), which
        # Trade#realized_gain_loss has already converted the proceeds into.
        amount = converted(gain.value, trade.entry.date, rates)
        next exclusions << :missing_exchange_rate if amount.nil?

        rows << { date: trade.entry.date, amount: amount }
      end

      @measured_rows = rows
      @exclusions = exclusions
    end

    def sell_trades
      return [] if account_ids.empty?

      trades = Trade
        .joins(:entry)
        .where(entries: { account_id: account_ids, date: period.date_range, excluded: false })
        .where("trades.qty < 0")
        # Rule 1, in SQL so these are never loaded. Trade#realized_gain_loss
        # independently returns nil for them; neither check is load-bearing
        # alone.
        .where(
          "trades.investment_activity_label IS NULL OR trades.investment_activity_label NOT IN (?)",
          Trade::INTERNAL_MOVEMENT_LABELS
        )
        .includes(entry: :account)
        .to_a
        .reject { |trade| after_cutoff?(trade) }

      preload(trades)
      trades
    end

    # A disabled account stops contributing on its cut-off date, as it stops
    # contributing to the balance series.
    def after_cutoff?(trade)
      cutoff = active_until_dates[trade.entry.account_id.to_s]
      cutoff.present? && trade.entry.date > cutoff
    end

    # One holdings query for every account and security involved, handed to
    # each trade so Trade#realized_gain_loss never looks one up per disposal,
    # then one query for the proceeds-to-basis rates those trades need.
    # Scoped to the securities actually sold and to the period's end.
    #
    # Holdings are preloaded first because Trade.preload_exchange_rates reads
    # the preloaded basis currency.
    def preload(trades)
      return if trades.empty?

      holdings = Holding
        .where(account_id: trades.map { |trade| trade.entry.account_id }.uniq, security_id: trades.map(&:security_id).uniq)
        .where("date <= ?", period.date_range.end)
        .order(date: :desc)
        .to_a
        .group_by(&:account_id)

      trades.each { |trade| trade.preloaded_holdings = holdings[trade.entry.account_id] || [] }
      Trade.preload_exchange_rates(trades)
    end

    # Rules 2 and 3: the sale date's rate, and nil -- never 1 -- when there is
    # none. (A stored rate is always positive: exchange_rates carries a
    # check constraint for it.)
    def converted(money, date, rates)
      from = money.currency.iso_code
      return money.amount if from == currency

      rate = rates[[ from, date ]]
      return nil if rate.nil?

      money.amount * rate
    end

    # `{ [from_currency, date] => rate }` for every foreign gain, in one query:
    # the rate on the sale date, else the nearest earlier one inside the
    # lookback window. A pair with none is absent.
    def target_rates(gains)
      wanted = gains.filter_map do |trade, gain|
        next if gain.nil?

        from = gain.value.currency.iso_code
        [ from, trade.entry.date ] unless from == currency
      end.uniq

      return {} if wanted.empty?

      lookback = ExchangeRate::Provided::NEAREST_RATE_LOOKBACK_DAYS
      windows = wanted.map(&:last).uniq.map { |date| (date - lookback)..date }
      stored = ExchangeRate
        .where(from_currency: wanted.map(&:first).uniq, to_currency: currency, date: windows)
        .order(date: :desc)
        .group_by(&:from_currency)

      wanted.each_with_object({}) do |(from, date), rates|
        nearest = stored[from]&.find { |rate| rate.date <= date && rate.date >= date - lookback }
        rates[[ from, date ]] = nearest.rate if nearest
      end
    end

    def account_ids
      @account_ids ||= accounts.map(&:id)
    end
end
