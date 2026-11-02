class BalanceSheet::NetWorthSeriesBuilder
  def initialize(family, user: nil, currency: nil)
    @family = family
    @user = user
    @currency = currency || family.currency
  end

  def net_worth_series(period: Period.last_30_days)
    Rails.cache.fetch(cache_key(period)) do
      builder = Balance::ChartSeriesBuilder.new(
        account_ids: historical_account_ids,
        account_active_until_dates: disabled_account_active_until_dates,
        currency: currency,
        period: period,
        favorable_direction: "up"
      )

      builder.balance_series
    end
  end

  private
    attr_reader :family, :user, :currency

    def historical_accounts
      @historical_accounts ||= historical_account_scope.relation.to_a
    end

    def historical_account_ids
      @historical_account_ids ||= historical_accounts.map(&:id)
    end

    def disabled_account_active_until_dates
      @disabled_account_active_until_dates ||= historical_accounts.each_with_object({}) do |account, dates|
        next unless account.disabled?

        disabled_on = (account.disabled_at || account.updated_at).to_date
        dates[account.id] = disabled_on - 1.day
      end
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
        currency,
        # A series built on the fallback before a rate arrived must not outlive
        # it. Balances convert by account currency, so only those pairs count;
        # with every account in the target currency there is nothing to query.
        ExchangeRate.cache_version(to: currency, from: historical_accounts.map(&:currency)),
        period.start_date,
        period.end_date
      ].compact.join("_")

      family.build_cache_key(
        key,
        invalidate_on_data_updates: true
      )
    end
end
