class Assistant::Function::GetAccounts < Assistant::Function
  class << self
    def name
      "get_accounts"
    end

    def description
      <<~INSTRUCTIONS
        Use this to see what accounts the user has along with their current balances.

        Returns account ids. Use them for account_ids filters in other tools.

        Pass include_balance_series: true only when the user asks about balance
        history; the series is omitted by default to keep responses small.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        include_balance_series: {
          type: "boolean",
          description: "Include a historical balance series per account (defaults to false)"
        },
        series_period: {
          type: "string",
          enum: Period::PERIODS.keys,
          description: "Period for the balance series (defaults to last_365_days)"
        }
      }
    )
  end

  def call(params = {})
    include_series = params["include_balance_series"] == true
    period = series_period(params)

    {
      as_of_date: Date.current,
      accounts: accounts_scope(include_series).map do |account|
        payload = {
          id: account.id,
          name: account.name,
          balance: account.balance,
          currency: account.currency,
          balance_formatted: account.balance_money.format,
          classification: account.classification,
          type: account.accountable_type,
          start_date: account.start_date,
          is_linked: account.linked?,
          provider: account.provider_name,
          status: account.status
        }

        if include_series
          series = historical_balances(account, period)
          payload[:historical_balances] = series if series
        end
        payload
      end
    }
  end

  private
    # No balances preload: the series goes through Balance::ChartSeriesBuilder,
    # which runs its own query keyed by account ids.
    def accounts_scope(_include_series)
      user.accessible_accounts.visible.includes(:account_providers)
    end

    def historical_balances(account, period)
      effective_start = [ account.start_date, period.start_date ].max
      # An account whose start date lies beyond the period (start_date derives
      # from the first entry, which can be future-dated) simply has no series;
      # it must not fail the whole accounts listing.
      return nil if effective_start > period.end_date

      effective = Period.custom(start_date: effective_start, end_date: period.end_date)
      balance_series = account.balance_series(period: effective, interval: effective.interval)

      to_ai_time_series(balance_series)
    end

    def series_period(params)
      key = params["series_period"].to_s

      Period.valid_key?(key) ? Period.from_key(key) : Period.from_key("last_365_days")
    end
end
