class BalanceSheet::NetWorthSeriesBuilder
  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  def net_worth_series(period: Period.last_30_days)
    Rails.cache.fetch(cache_key(period)) do
      builder = Balance::ChartSeriesBuilder.new(
        account_ids: historical_account_ids,
        account_active_until_dates: disabled_account_active_until_dates,
        currency: family.currency,
        period: period,
        favorable_direction: "up"
      )

      builder.balance_series
    end
  end

  # Net worth counting only what is available on each day: immediate and
  # short-term assets, locked assets from their release date on, minus
  # short-term liabilities (Account::Liquidity). Uses today's levels for
  # every day; only the release date moves with the day.
  def available_net_worth_series(period: Period.last_30_days)
    Rails.cache.fetch(cache_key(period, "available")) do
      accounts = historical_accounts.select { |account| available_at_some_point?(account) }

      builder = Balance::ChartSeriesBuilder.new(
        account_ids: accounts.map(&:id),
        account_active_until_dates: disabled_account_active_until_dates.slice(*accounts.map(&:id)),
        account_active_from_dates: release_dates(accounts),
        currency: family.currency,
        period: period,
        favorable_direction: "up"
      )

      builder.balance_series
    end
  end

  private
    attr_reader :family, :user

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

    def available_at_some_point?(account)
      return true if account.liquidity.in?(Account::Liquidity::AVAILABLE_LEVELS)

      account.asset? && released_locked?(account)
    end

    def released_locked?(account)
      account.liquidity == "locked" && !account.auto_renew? && account.available_on.present?
    end

    # Locked assets count from their release date on; everything else in the
    # series counts on every day.
    def release_dates(accounts)
      accounts.each_with_object({}) do |account, dates|
        dates[account.id] = account.available_on if released_locked?(account)
      end
    end

    def cache_key(period, variant = nil)
      shares_version = user ? AccountShare.where(user: user).maximum(:updated_at)&.to_i : nil
      key = [
        "balance_sheet_net_worth_series_historical",
        variant,
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
