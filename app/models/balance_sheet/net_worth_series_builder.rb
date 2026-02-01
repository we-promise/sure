class BalanceSheet::NetWorthSeriesBuilder
  def initialize(family)
    @family = family
  end

  def net_worth_series(period: Period.last_30_days)
    Rails.cache.fetch(cache_key(period)) do
      builder = Balance::ChartSeriesBuilder.new(
        account_ids: visible_account_ids,
        currency: family.currency,
        period: period,
        favorable_direction: "up"
      )

      builder.balance_series
    end
  end

  private
    attr_reader :family

    def visible_account_ids
      @visible_account_ids ||= family.accounts.visible.with_attached_logo.pluck(:id)
    end

    def cache_key(period)
      # Build a cache key that ONLY includes visible accounts' updated_at timestamps.
      # This prevents disabled accounts from affecting the cache key while the cached
      # data only contains visible accounts, which could cause stale data issues.
      visible_max_updated_at = family.accounts.visible.maximum(:updated_at)

      [
        family.id,
        "balance_sheet_net_worth_series",
        period.start_date,
        period.end_date,
        family.latest_sync_completed_at,
        visible_max_updated_at
      ].compact.join("_")
    end
end
