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
  # Investment series are normalized from holdings and entries that can change outside
  # this account's syncs, so those keep the family-wide sync timestamp.
  def sparkline_cache_key
    @sparkline_cache_key ||= [
      "account_sparkline", SPARKLINE_CACHE_VERSION, id, updated_at.to_f, last_synced_at&.to_f,
      rows_version(balances), rows_version(account_providers), Date.current,
      (family.latest_sync_completed_at&.to_f if balance_type == :investment)
    ].join("_")
  end

  private
    def rows_version(scope)
      scope.pick(Arel.sql("count(*)"), Arel.sql("max(#{scope.table_name}.updated_at)")).map { |v| v&.to_f }.join("-")
    end

    def normalize_linked_investment_series(series, view: :balance)
      Balance::LinkedInvestmentSeriesNormalizer.new(account: self, series: series, view: view).normalize
    end
end
