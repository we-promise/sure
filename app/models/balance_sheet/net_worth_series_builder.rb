class BalanceSheet::NetWorthSeriesBuilder
  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  def net_worth_series(period: Period.last_30_days)
    Rails.cache.fetch(cache_key(period)) do
      builder = Balance::ChartSeriesBuilder.new(
        account_ids: historical_account_ids,
        currency: family.currency,
        period: period,
        favorable_direction: "up"
      )

      builder.balance_series
    end
  end

  private
    attr_reader :family, :user

    def historical_account_ids
      @historical_account_ids ||= historical_account_scope.account_ids
    end

    def historical_account_scope
      @historical_account_scope ||= BalanceSheet::HistoricalAccountScope.new(family, user: user)
    end

    def cache_key(period)
      shares_version = user ? AccountShare.where(user: user).maximum(:updated_at)&.to_i : nil
      key = [
        "balance_sheet_net_worth_series_historical",
        user&.id,
        shares_version,
        period.start_date,
        period.end_date
      ].compact.join("_")

      family.build_cache_key(
        key,
        invalidate_on_data_updates: true
      )
    end
end
