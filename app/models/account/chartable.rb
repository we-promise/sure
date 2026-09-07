module Account::Chartable
  extend ActiveSupport::Concern
  SPARKLINE_CACHE_VERSION = "v4"

  def favorable_direction
    classification == "asset" ? "up" : "down"
  end

  # D5 / FR-501: what "All" means on THIS account's chart.
  #
  # `Period::PERIODS["all_time"]` starts at `Current.family.oldest_entry_date`,
  # which is family-scoped. A loan opened last year in a family with five years
  # of history charts four years of COALESCE-to-zero before the loan exists and
  # then jumps -- a shape that reads as a sudden debt rather than an origination.
  #
  # Deliberately LOAN-ONLY. Account-scoped all-time is a real improvement for
  # every account type, but making it here would change investment, depository
  # and property charts on the back of a loan requirement, with no acceptance
  # criteria for those types and no product sign-off this epic can obtain
  # (risks R10/R11). The general version belongs upstream, with its own
  # fixtures -- see the follow-up issue. `Period::PERIODS` is untouched, so net
  # worth, reports and the dashboard are unaffected by construction.
  def chart_period(requested_period = nil)
    requested_period ||= Period.last_30_days
    return requested_period unless loan_scoped_all_time?(requested_period)

    start_date = chart_start_date
    return requested_period if start_date.blank? || start_date >= Date.current

    Period.custom(start_date: start_date, end_date: Date.current)
  end

  # Returns the chart Series for this account over the given period.
  # Supported views: :balance, :cash_balance, :holdings_balance, :gains.
  def balance_series(period: Period.last_30_days, view: :balance, interval: nil)
    raise ArgumentError, "Invalid view type" unless [ :balance, :cash_balance, :holdings_balance, :gains ].include?(view.to_sym)

    @balance_series ||= {}

    memo_key = [ period.start_date, period.end_date, interval ].compact.join("_")

    builder = (@balance_series[memo_key] ||= Balance::ChartSeriesBuilder.new(
      account_ids: [ id ],
      currency: self.currency,
      period: period,
      favorable_direction: favorable_direction,
      interval: interval
    ))

    normalize_linked_investment_series(builder.send("#{view}_series"))
  end

  def sparkline_series
    cache_key = family.build_cache_key("#{id}_sparkline_#{SPARKLINE_CACHE_VERSION}", invalidate_on_data_updates: true)

    Rails.cache.fetch(cache_key, expires_in: 24.hours) do
      balance_series
    end
  end

  private
    # Both conditions matter. Only loans, and only the "all_time" key: every
    # other period, and every other account type, is left exactly as the caller
    # asked for. Dropping either half is the bug this branch has to avoid --
    # without the key check it would rewrite 1M and YTD too.
    def loan_scoped_all_time?(period)
      period.key.to_s == "all_time" && accountable.is_a?(Loan)
    end

    # `min(opening anchor, oldest entry)` -- the same expression the balance
    # calculator already uses to decide the earliest date balances exist for.
    # Reused rather than re-derived: a chart that starts before the first
    # materialised balance is the flat-zero segment this method exists to
    # remove, one step earlier.
    def chart_start_date
      Balance::BaseCalculator.new(self).calculation_start_date
    end

    def normalize_linked_investment_series(series)
      Balance::LinkedInvestmentSeriesNormalizer.new(account: self, series: series).normalize
    end
end
