class BalanceSheet::NetWorthSeriesBuilder
  # `accounts:` (an Account relation) narrows the series to a subset of what
  # the user (or, without one, the family) would otherwise get, e.g. the
  # insights feed's accounts every member may see.
  def initialize(family, user: nil, accounts: nil)
    @family = family
    @user = user
    @accounts = accounts
  end

  def net_worth_series(period: Period.last_30_days)
    Rails.cache.fetch(cache_key(period)) do
      builder = Balance::ChartSeriesBuilder.new(
        account_ids: historical_account_ids,
        account_active_until_dates: account_active_until_dates,
        currency: family.currency,
        period: period,
        favorable_direction: "up"
      )

      builder.balance_series
    end
  end

  private
    attr_reader :family, :user, :accounts

    def historical_accounts
      @historical_accounts ||= begin
        scope = historical_account_scope.relation
        scope = scope.where(id: accounts.select(:id)) if accounts
        scope.to_a
      end
    end

    def historical_account_ids
      @historical_account_ids ||= historical_accounts.map(&:id)
    end

    def account_active_until_dates
      @account_active_until_dates ||= disabled_account_active_until_dates
        .merge(zero_balance_account_active_until_dates) { |_account_id, disabled_until, zero_until| [ disabled_until, zero_until ].min }
    end

    def disabled_account_active_until_dates
      @disabled_account_active_until_dates ||= historical_accounts.each_with_object({}) do |account, dates|
        next unless account.disabled?

        disabled_on = (account.disabled_at || account.updated_at).to_date
        dates[account.id] = disabled_on - 1.day
      end
    end

    # A zero balance is carried forward, so the account contributes nothing
    # after its last entry. An account still holding a balance stays in.
    def zero_balance_account_active_until_dates
      @zero_balance_account_active_until_dates ||= latest_balances.each_with_object({}) do |(account_id, date, end_balance), dates|
        dates[account_id] = date if end_balance.zero?
      end
    end

    # One indexed lookup per account. A `DISTINCT ON` over the account's whole
    # balance history reads every row on a cache miss, which is slower than
    # the chart query this change removes.
    def latest_balances
      return [] if historical_account_ids.empty?

      Account
        .where(id: historical_account_ids)
        .joins(<<~SQL.squish)
          CROSS JOIN LATERAL (
            SELECT balances.account_id, balances.date, balances.end_balance
            FROM balances
            WHERE balances.account_id = accounts.id
              AND balances.currency = accounts.currency
            ORDER BY balances.date DESC
            LIMIT 1
          ) latest_balances
        SQL
        .pluck("latest_balances.account_id", "latest_balances.date", "latest_balances.end_balance")
    end

    def historical_account_scope
      @historical_account_scope ||= BalanceSheet::HistoricalAccountScope.new(family, user: user)
    end

    def cache_key(period)
      shares_version = user ? AccountShare.where(user: user).maximum(:updated_at)&.to_i : nil
      key = [
        "balance_sheet_net_worth_series_historical",
        ExchangeRate::CONVERSION_CACHE_VERSION,
        # A rate stored later can bring back an account the series left out.
        ExchangeRate.updated_at_version,
        user&.id,
        shares_version,
        accounts_digest,
        period.start_date,
        period.end_date
      ].compact.join("_")

      family.build_cache_key(
        key,
        invalidate_on_data_updates: true
      )
    end

    # A narrowed series must not share a cache entry with the full one, and a
    # share granted or revoked changes the set, so the key carries the ids.
    def accounts_digest
      return nil unless accounts

      Digest::MD5.hexdigest(historical_account_ids.sort.join(","))
    end
end
