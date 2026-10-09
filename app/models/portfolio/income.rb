# Dividend and interest income over a period, by the month it was paid, and
# the fees charged against the same scope.
#
# This is a REGROUPING of rows that already exist, not a new measurement. The
# daily rows carry `income` and `fees` already classified by
# Portfolio::FlowClassifier -- Trade-shaped (qty 0, since #1311)
# and Transaction-shaped (Trading212, SimpleFIN) alike -- and already converted
# at the day each was paid. Portfolio::Drivers sums the same fields over the
# whole period; this groups them by calendar month. The two therefore agree by
# construction, and the drivers' reconciliation is untouched because nothing here
# reclassifies a row: a reader that re-derived "is this a dividend?" for itself
# is the thing the classifier exists to prevent.
#
# WHAT THIS DOES NOT DO is attribute income to a security. The daily rows are
# scope-wide, and a Transaction-shaped dividend carries a security only when the
# provider recorded one (Transaction#activity_security).
class Portfolio::Income
  # One calendar month in which income was paid. A month that paid nothing is
  # absent rather than present as a zero: an empty bar and a month that netted
  # to nothing are different facts.
  Bucket = Data.define(:month, :amount)

  attr_reader :daily_returns

  def initialize(daily_returns)
    @daily_returns = daily_returns
  end

  # Months with income, oldest first.
  def buckets
    @buckets ||= rows
      .group_by { |row| row.date.beginning_of_month }
      .filter_map { |month, month_rows| build_bucket(month, month_rows) }
      .sort_by(&:month)
  end

  def total
    @total ||= rows.sum(BigDecimal(0), &:income)
  end

  # Charges are positive, as Portfolio::Drivers#fees is; a "Fee" rebate is a
  # :fee with a negative amount (Portfolio::FlowClassifier), so a period whose
  # rebates exceed its charges sums negative. A fee is not negative income:
  # folding it into a bar would hide what a payout cost inside the payout.
  def fees
    @fees ||= rows.sum(BigDecimal(0), &:fees)
  end

  # Whether the period paid any income. Fees alone do not count: this gates the
  # income chart.
  def any?
    buckets.any?
  end

  # The mean of the period's daily closing values.
  #
  # The denominator of #fee_ratio, and the mean rather than either end because
  # the ratio asks "what did holding this cost, relative to what was held",
  # and a portfolio that tripled by the last day was not 3x as large on the
  # days the fee was charged. Taken over today's value (or the closing one) a
  # fee ratio shrinks every time the portfolio grows, which is the wrong way
  # round for a cost figure.
  #
  # LIMITATION: `rows` has one row per calendar day of the period, and a day
  # before the portfolio's first balance row has a value of zero. A period that
  # opens before the portfolio existed therefore averages those zeros in, which
  # lowers the denominator and inflates #fee_ratio. It is a mean over the period
  # as asked for, not over the days the portfolio was invested, and it is left
  # that way because the second reading would change what the figure means
  # (and what the period label above it says it covers).
  def average_value
    return BigDecimal(0) if rows.empty?

    @average_value ||= rows.sum(BigDecimal(0), &:value_close) / rows.size
  end

  # Fees over the period's average value, as a fraction (0.01 == 1%), for the
  # whole period -- not annualised. nil when the period held no value to divide
  # by: that is "no ratio", not a ratio of zero.
  def fee_ratio
    return nil unless average_value.positive?

    fees / average_value
  end

  # The shape Portfolio::Performance caches. Plain values only, so it survives
  # Rails.cache the way Portfolio::Drivers#to_h does.
  #
  # Each bucket's `month` is an ISO 8601 date string ("2026-03-01"), not a
  # Date. A Marshal-based store would hand a Date back, but one with a JSON
  # serializer turns it into this string anyway, so a caller would read a Date
  # or a String depending on the store. As a string it reads the same from
  # every store; `Date.iso8601` turns it back into the month.
  def to_h
    {
      buckets: buckets.map { |bucket| { month: bucket.month.iso8601, amount: bucket.amount } },
      total: total,
      fees: fees,
      average_value: average_value,
      fee_ratio: fee_ratio
    }
  end

  private
    def rows
      daily_returns.rows
    end

    # nil for a month in which no income row is non-zero, which is a month that
    # paid nothing. A month with activity is kept even when it nets to zero (a
    # payout and its reversal) or negative (a reversal larger than that month's
    # payments): dropping it would report an active month as absent, and a
    # negative one would leave the buckets short of #total.
    def build_bucket(month, month_rows)
      return nil if month_rows.all? { |row| row.income.zero? }

      Bucket.new(month: month, amount: month_rows.sum(BigDecimal(0), &:income))
    end
end
