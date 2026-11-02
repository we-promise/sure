module Account::Chartable
  extend ActiveSupport::Concern
  SPARKLINE_CACHE_VERSION = "v4"

  def favorable_direction
    classification == "asset" ? "up" : "down"
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

    normalize_linked_investment_series(builder.send("#{view}_series"), view: view)
  end

  def sparkline_series
    Rails.cache.fetch(sparkline_cache_key, expires_in: 24.hours) do
      balance_series
    end
  end

  # Built from this account's own data, so a sync of another account keeps it cached.
  def sparkline_cache_key
    @sparkline_cache_key ||= begin
      balance_count, balances_updated_at = balances.pick(Arel.sql("count(*)"), Arel.sql("max(balances.updated_at)"))

      [
        "account_sparkline", SPARKLINE_CACHE_VERSION, id, updated_at.to_f, last_synced_at&.to_f, linked?,
        balance_count, balances_updated_at&.to_f, Date.current
      ].join("_")
    end
  end

  private
    def normalize_linked_investment_series(series, view: :balance)
      Balance::LinkedInvestmentSeriesNormalizer.new(account: self, series: series, view: view).normalize
    end
end
