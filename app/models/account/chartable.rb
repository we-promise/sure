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
    # account whose value line is trimmed to supported history, it opens at
    # the trim date's closing value and adds only the flows after it, so the
    # two lines start together and the difference opens at zero. The anchor
    # comes from the account's history, not the period, so it is the same
    # whichever period is shown.
    #
    # On the anchor date itself the line takes the value line's own point.
    # They are the same figure unless a coarse interval skipped that date and
    # the normalizer prepended a synthetic opening point (0, or the opening
    # anchor's balance); the line then starts from that point too, rather
    # than from a different figure on the same day.
    def net_contributions_series(period:, interval:)
      value_series = balance_series(period: period, view: :balance, interval: interval)
      value_dates = value_series.values.map(&:date)
      anchor_date = net_contributions_anchor_date
      series = chart_series_builder(period: period, interval: interval)
        .net_contributions_series(anchor_date: anchor_date, dates: value_dates)

      anchor_point = anchor_date && value_series.values.find { |value| value.date == anchor_date }
      amounts = series.values.map do |value|
        anchor_point && value.date == anchor_date ? anchor_point.value : value.value
      end

      Series.new(
        start_date: value_dates.min || series.start_date,
        end_date: series.end_date,
        interval: series.interval,
        values: series.values.zip(amounts).each_with_index.map do |(value, amount), index|
          Series::Value.new(
            date: value.date,
            date_formatted: value.date_formatted,
            value: amount,
            trend: Trend.new(current: amount, previous: index.zero? ? amount : amounts[index - 1], favorable_direction: series.favorable_direction)
          )
        end,
        favorable_direction: series.favorable_direction
      )
    end

    def net_contributions_anchor_date
      return unless linked? && balance_type == :investment

      Balance::LinkedInvestmentSeriesNormalizer.supported_history_start_date(self)
    end

    def normalize_linked_investment_series(series, view: :balance)
      Balance::LinkedInvestmentSeriesNormalizer.new(account: self, series: series, view: view).normalize
    end
end
