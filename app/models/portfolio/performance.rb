# The performance metric surface for a set of accounts over a period.
#
# A value object in the shape of Loan::SimulationResult: constructed
# with its boundaries, computes once, answers questions.
#
# CACHING. The key comes from Family#build_cache_key with
# `invalidate_on_data_updates: true`, which folds in `latest_sync_completed_at`.
# `entries_cache_version` -- the key the rest of InvestmentStatement uses -- is
# NOT sufficient here: it is `entries.count` plus `entries.maximum(:updated_at)`,
# and a daily price sync changes holdings and therefore balances while touching
# no entry at all. Returns cached on it would stay stale until the user next
# edited a transaction.
#
# The family currency is in the key too. Every figure is converted into it,
# and Family#build_cache_key does not include it, so a family that
# changes currency would otherwise be served figures in the previous one.
class Portfolio::Performance
  # Bumped whenever the meaning of a cached figure changes, so warm caches stop
  # serving the old interpretation under the same name (the pattern #3350 used
  # for totals_query/v2).
  CACHE_VERSION = "v7".freeze

  # The balance rows are calendar daily, so the series includes weekends and
  # holidays as structural zeros. Annualising that by the trading-day convention
  # (252) would overstate the result; the calendar year is the honest divisor
  # for a calendar-daily series.
  TRADING_PERIODS_PER_YEAR = 365

  # Calendar days per year, for turning a day count into a year fraction. The
  # same number as TRADING_PERIODS_PER_YEAR today and deliberately a separate
  # constant: that one counts return OBSERVATIONS, to scale a standard
  # deviation, and this one counts DAYS. Move the series to weekly balances and
  # the first becomes 52 while this must stay 365, so binding them together
  # would quietly corrupt annualisation the day the interval changed.
  DAYS_PER_YEAR = 365.0

  # Annualising anything shorter produces a number nobody should be shown.
  MIN_DAYS_FOR_ANNUALISATION = 365

  attr_reader :family, :account_ids, :period, :user, :active_until_dates

  def initialize(family:, account_ids:, period:, user: nil, active_until_dates: {})
    @family = family
    @account_ids = Array(account_ids).compact.map(&:to_s)
    @period = period
    @user = user
    @active_until_dates = active_until_dates || {}
  end

  # Chained daily returns, as a BigDecimal fraction (0.21 == 21%).
  # nil when there is nothing to report or a rate is missing.
  def time_weighted_return
    metrics[:twr]
  end
  alias_method :twr, :time_weighted_return

  # nil below MIN_DAYS_FOR_ANNUALISATION.
  def annualized_time_weighted_return
    metrics[:annualized_twr]
  end
  alias_method :annualized_twr, :annualized_time_weighted_return

  # The money-weighted return over the period, as a BigDecimal fraction.
  # nil when the scope cannot support it, or XIRR could not solve.
  def money_weighted_return
    metrics[:mwr]
  end
  alias_method :mwr, :money_weighted_return

  # The annualised money-weighted return, nil below
  # MIN_DAYS_FOR_ANNUALISATION, exactly as annualized_twr is. Annualising a
  # few days' return states a figure the assets never earned.
  def annualized_money_weighted_return
    metrics[:annualized_mwr]
  end
  alias_method :annualized_mwr, :annualized_money_weighted_return

  # Annualised standard deviation of daily returns.
  def volatility
    metrics[:volatility]
  end

  # Largest peak-to-trough fall of the chained index, as a positive fraction.
  def max_drawdown
    metrics[:max_drawdown]
  end

  # [[date, index], ...] rebased on a base of 100, where the FIRST point is the
  # level after the first return (100 * (1 + r1)), not the base itself. This is the
  # flow-adjusted series a chart plots: it removes the effect of deposits, so it
  # can be laid beside a benchmark without the shapes disagreeing purely
  # because money went in.
  def index_series
    metrics[:index_series]
  end

  def drivers
    metrics[:drivers]
  end

  # True when a currency pair had no rate anywhere in the period, in which
  # case every return figure is nil and the UI must say why rather than showing
  # a parity-converted number.
  def rate_missing?
    metrics[:rate_missing]
  end

  # Days whose denominator was zero or negative.
  def suppressed_dates
    metrics[:suppressed_dates]
  end

  def any?
    account_ids.any? && metrics[:day_count] > 0
  end

  # Exposed for tests and for callers that want the raw series.
  def daily_returns
    @daily_returns ||= Portfolio::DailyReturns.new(
      account_ids: account_ids,
      currency: family.currency,
      period: period,
      active_until_dates: active_until_dates
    )
  end

  # Every constructor argument that can change a figure has to be in here.
  # `active_until_dates` is easy to forget because it is not passed today, but
  # it changes the underlying rows materially -- a cut-off date drops an
  # account's later history entirely -- so omitting it would let the first
  # caller to use it read another caller's cached answer.
  #
  # The cut-off dates are keyed as DailyReturns resolves them, not as they were
  # passed: DailyReturns compacts them and normalises each value to an ISO8601
  # string, so `{ id => nil }` is valid input meaning "no cut-off" and has to
  # key identically to an omitted hash -- which it does only after that
  # compaction, and a key-type difference would key two identical scopes
  # differently.
  #
  # Nothing is converted here for the same reason: the resolved values are
  # already the strings DailyReturns keyed its own query on, so a `to_date`
  # round trip would only re-parse them.
  #
  # The digest only shortens the key; nothing depends on it being secret.
  # SHA-256 rather than MD5 so code scanning does not flag account ids fed to a
  # broken hash.
  def cache_key
    family.build_cache_key(
      [
        "portfolio_performance", CACHE_VERSION, user&.id, family.currency,
        Digest::SHA256.hexdigest(
          [
            account_ids.sort.join(","),
            daily_returns.active_until_dates.map { |id, date| "#{id}:#{date}" }.sort.join(",")
          ].join("|")
        ),
        period.start_date, period.end_date
      ].compact.join("_"),
      invalidate_on_data_updates: true
    )
  end

  private
    def metrics
      @metrics ||= Rails.cache.fetch(cache_key) { compute }
    end

    def compute
      rows = daily_returns.rows
      returns = daily_returns.returns
      rate_missing = daily_returns.rate_missing?

      drivers = Portfolio::Drivers.new(daily_returns)

      # A missing rate makes every ratio unsafe, so the figures are
      # withheld. The drivers are still reported -- they are money, and the
      # caller can see which part is unexplained -- but nothing is expressed as
      # a percentage of a value we could not convert.
      #
      # Applied to the whole scope: an account with a single day of balance
      # history supports no return, so it withholds every time-weighted figure.
      withhold_time_weighted = rate_missing || !time_weighted_supported?
      chained = withhold_time_weighted ? nil : chain(returns)
      money_weighted_rate = rate_missing || !money_weighted_supported?(rows) ? nil : money_weighted(rows)

      {
        twr: chained,
        annualized_twr: annualize(chained),
        # Period basis. The annualised form is :annualized_mwr, nil under a year.
        mwr: money_weighted_rate,
        annualized_mwr: annualize(money_weighted_rate),
        volatility: withhold_time_weighted ? nil : annualized_volatility(returns),
        max_drawdown: withhold_time_weighted ? nil : drawdown(returns),
        index_series: withhold_time_weighted ? [] : rebased_index(returns),
        drivers: drivers.to_h,
        rate_missing: rate_missing,
        suppressed_dates: rows.select(&:suppressed).map(&:date),
        day_count: rows.size
      }
    end

    def chain(returns)
      return nil if returns.empty?

      returns.reduce(BigDecimal(1)) { |acc, (_date, r)| acc * (1 + r) } - 1
    end

    def annualize(chained)
      return nil if chained.nil?
      return nil if period.days < MIN_DAYS_FOR_ANNUALISATION

      years = period.days / DAYS_PER_YEAR
      growth = (1 + chained).to_f
      # A total loss leaves nothing to annualise; the root of a negative is not
      # a return.
      return nil if growth <= 0

      BigDecimal(((growth**(1.0 / years)) - 1).to_s)
    end

    # Eligibility applied to the whole scope. A money-weighted return over
    # several accounts is only as good as the flows of every account in it:
    # a valuation-tracked account's flows are unknown, and an account with one
    # day of history has no opening position to measure from, so either one
    # withholds the figure. An account with no balance rows in the period
    # contributes nothing and does not block it, the same rule a missing rate
    # follows. A period of fewer than two days has no duration to annualise.
    def money_weighted_supported?(rows)
      return false if rows.size < 2

      return_scopes.values.all? do |scope|
        scope.balance_days.zero? || scope.supports_money_weighted_return?
      end
    end

    # Eligibility for every account in the scope, resolved once per instance.
    # Both #money_weighted_supported? and #time_weighted_supported? read it, and
    # both run inside the uncached compute behind Rails.cache.fetch, so a
    # cache miss costs the account load plus three resolution queries, once,
    # rather than that load plus up to four queries per account, twice.
    def return_scopes
      @return_scopes ||= Portfolio::ReturnScope.resolve_all(
        accounts: Account.where(id: account_ids),
        period: period
      )
    end

    # Eligibility applied to the whole scope for the time-weighted figures, mirroring
    # #money_weighted_supported?: an account with exactly one day of balance
    # history has no return to contribute, so it withholds the aggregate. An
    # account with no balance rows in the period contributes nothing and does
    # not block it.
    def time_weighted_supported?
      return_scopes.values.none? { |scope| scope.balance_days == 1 }
    end

    # The opening value is the investor's first outlay; every flow
    # follows -- external flows, and the value an account brought into or carried
    # out of the scope -- and the closing value is what they could walk away with.
    #
    # Solved over the period, not the year. The rate is expressed in units of
    # the interval the rows cover, so the figure is the return over the period
    # rather than an extrapolation of it to a year -- the rule that
    # annualises nothing below a year, applied to the money-weighted figure.
    #
    # The closing value is dated at the END of the last row's day, which is the
    # start of the next. A row's value_open is the previous day's close and its
    # value_close is that day's, so N rows are N days of exposure and N daily
    # returns -- the interval the time-weighted figure chains over, and the one
    # Period#days counts. Dating the closing flow at the last row's own date
    # instead would compress the series by a day: the money was at work for N
    # days but discounted over N-1, which annualised to a figure about four
    # basis points off the annual XIRR of the same flows over a year.
    def money_weighted(rows)
      return nil if rows.empty?

      # The end of the last day, not the start of it.
      closing_date = rows.last.date + 1
      span_in_days = (closing_date - rows.first.date).to_i
      return nil unless span_in_days.positive?

      opening = rows.first.value_open
      closing = rows.last.value_close

      flows = []
      flows << Portfolio::Xirr::Flow.new(date: rows.first.date, amount: -opening) unless opening.zero?

      rows.each do |row|
        flow = row.external_flow + row.composition_flow
        next if flow.zero?
        flows << Portfolio::Xirr::Flow.new(date: row.date, amount: -flow)
      end

      flows << Portfolio::Xirr::Flow.new(date: closing_date, amount: closing) unless closing.zero?

      Portfolio::Xirr.rate_or_nil(flows, days_per_unit: span_in_days)
    end

    def annualized_volatility(returns)
      values = returns.map { |(_date, r)| r.to_f }
      return nil if values.size < 2

      mean = values.sum / values.size
      variance = values.sum { |v| (v - mean)**2 } / (values.size - 1)
      return nil if variance.negative?

      BigDecimal((Math.sqrt(variance) * Math.sqrt(TRADING_PERIODS_PER_YEAR)).to_s)
    end

    def drawdown(returns)
      return nil if returns.empty?

      peak = BigDecimal(1)
      level = BigDecimal(1)
      worst = BigDecimal(0)

      returns.each do |(_date, r)|
        level *= (1 + r)
        peak = level if level > peak
        next unless peak.positive?

        fall = (peak - level) / peak
        worst = fall if fall > worst
      end

      worst
    end

    def rebased_index(returns)
      level = BigDecimal(100)

      returns.map do |(date, r)|
        level *= (1 + r)
        [ date, level ]
      end
    end
end
