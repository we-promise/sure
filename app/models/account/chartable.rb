module Account::Chartable
  extend ActiveSupport::Concern
  SPARKLINE_CACHE_VERSION = "v4"

  def favorable_direction
    classification == "asset" ? "up" : "down"
  end

  # Returns the chart Series for this account over the given period.
  # Supported views: :balance, :cash_balance, :holdings_balance, :gains,
  # :net_contributions.
  def balance_series(period: Period.last_30_days, view: :balance, interval: nil)
    raise ArgumentError, "Invalid view type" unless [ :balance, :cash_balance, :holdings_balance, :gains, :net_contributions ].include?(view.to_sym)
    return net_contributions_series(period: period, interval: interval) if view.to_sym == :net_contributions

    builder = chart_series_builder(period: period, interval: interval)

    normalize_linked_investment_series(builder.send("#{view}_series"), view: view)
  end

  # True when a flow the net contributions line counts could not be valued,
  # so the chart can say the line is understated.
  def net_contributions_understated?(period: Period.last_30_days, interval: nil)
    value_dates = balance_series(period: period, view: :balance, interval: interval).values.map(&:date)

    chart_series_builder(period: period, interval: interval)
      .net_contributions_understated?(anchor_date: net_contributions_anchor_date, dates: value_dates)
  end

  def sparkline_series
    cache_key = family.build_cache_key("#{id}_sparkline_#{SPARKLINE_CACHE_VERSION}", invalidate_on_data_updates: true)

    Rails.cache.fetch(cache_key, expires_in: 24.hours) do
      balance_series
    end
  end

  private
    # One builder per period and interval, so the views of one chart share its
    # memoized balance query.
    def chart_series_builder(period:, interval:)
      @balance_series ||= {}

      memo_key = [ period.start_date, period.end_date, interval ].compact.join("_")

      @balance_series[memo_key] ||= Balance::ChartSeriesBuilder.new(
        account_ids: [ id ],
        currency: self.currency,
        period: period,
        favorable_direction: favorable_direction,
        interval: interval
      )
    end

    # Net contributions on the same dates as the Total value line.
    #
    # The normalizer does not run on this series: it would prepend a
    # synthetic opening point of its own. Instead the line is sampled on the
    # value line's dates, after that line's trim. For a linked investment
    # account whose value line is trimmed to supported history, the line
    # starts from the balance held before the trim day's activity and counts
    # that day's flows (#382), so the gap between the lines is the market's
    # from the trim date on. The anchor comes from the account's history,
    # not the period, so it is the same whichever period is shown.
    #
    # On the anchor date the line is measured at the same moment as the
    # value line's own point there. That point is the day's close when the
    # balance query sampled it unchanged, and the balance before the day's
    # activity when the normalizer supplied it instead (a coarse interval's
    # prepended opening, or upstream #4009's reset of the first point).
    def net_contributions_series(period:, interval:)
      builder = chart_series_builder(period: period, interval: interval)
      value_series = balance_series(period: period, view: :balance, interval: interval)
      value_dates = value_series.values.map(&:date)
      anchor_date = net_contributions_anchor_date
      series = builder.net_contributions_series(
        anchor_date: anchor_date,
        dates: value_dates,
        anchor_before_activity: value_point_before_activity?(value_series, builder: builder, date: anchor_date)
      )

      Series.new(
        start_date: value_dates.min || series.start_date,
        end_date: series.end_date,
        interval: series.interval,
        values: series.values,
        favorable_direction: series.favorable_direction
      )
    end

    # True when the value line's point on `date` is not the close the
    # balance query gave for that date: the normalizer prepended it or reset
    # it to the balance before the day's activity. False when there is no
    # such point.
    #
    # Known limit: once upstream #4009 resets the first point to the balance
    # before the day's activity, a reset point whose value equals the day's
    # close (a flow offset by the market) is read as the close. Fixed in the
    # sync that brings in #4009.
    def value_point_before_activity?(value_series, builder:, date:)
      point = date && value_series.values.find { |value| value.date == date }
      return false unless point

      close = builder.balance_series.values.find { |value| value.date == date }
      close.nil? || close.value != point.value
    end

    def net_contributions_anchor_date
      return unless linked? && balance_type == :investment

      Balance::LinkedInvestmentSeriesNormalizer.supported_history_start_date(self)
    end

    def normalize_linked_investment_series(series, view: :balance)
      Balance::LinkedInvestmentSeriesNormalizer.new(account: self, series: series, view: view).normalize
    end
end
