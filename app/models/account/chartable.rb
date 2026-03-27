module Account::Chartable
  extend ActiveSupport::Concern
  SPARKLINE_CACHE_VERSION = "v2"

  def favorable_direction
    classification == "asset" ? "up" : "down"
  end

  def balance_series(period: Period.last_30_days, view: :balance, interval: nil)
    raise ArgumentError, "Invalid view type" unless [ :balance, :cash_balance, :holdings_balance ].include?(view.to_sym)

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
    def normalize_linked_investment_series(series)
      Balance::LinkedInvestmentSeriesNormalizer.new(account: self, series: series).normalize
    end
end
