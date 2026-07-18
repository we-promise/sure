class BalanceSheet::NetWorthBreakdownSeriesBuilder
  # Monthly interval regardless of period length so the reports chart always
  # shows one point per month in the selected range.
  INTERVAL = "1 month"

  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  # Returns a chart payload where each monthly point carries the net worth
  # value plus a per-account-group breakdown (grouped by accountable type)
  # split into assets and liabilities, for rendering in chart tooltips.
  def breakdown_series(period:)
    Rails.cache.fetch(cache_key(period)) do
      net_series = series_for(historical_accounts, favorable_direction: "up", period: period)
      groups = group_series(period)

      {
        start_date: period.start_date,
        end_date: period.end_date,
        interval: INTERVAL,
        trend: net_series.trend,
        values: net_series.values.map { |value| breakdown_value(value, groups) }
      }
    end
  end

  private
    attr_reader :family, :user

    def breakdown_value(value, groups)
      point_groups = groups.map do |group|
        {
          name: group[:name],
          color: group[:color],
          classification: group[:classification],
          value: group[:values_by_date][value.date] || Money.new(0, family.currency)
        }
      end

      {
        date: value.date,
        date_formatted: value.date_formatted,
        value: value.value,
        trend: value.trend,
        assets: classification_total(point_groups, "asset"),
        liabilities: classification_total(point_groups, "liability"),
        groups: point_groups
      }
    end

    def classification_total(point_groups, classification)
      total = point_groups
        .select { |group| group[:classification] == classification }
        .sum { |group| group[:value].amount }

      Money.new(total, family.currency)
    end

    def group_series(period)
      grouped_accounts.filter_map do |(classification, accountable), accounts|
        direction = classification == "asset" ? "up" : "down"
        series = series_for(accounts, favorable_direction: direction, period: period)
        values_by_date = series.values.index_by(&:date).transform_values(&:value)

        next if values_by_date.values.all? { |money| money.amount.zero? }

        {
          name: accountable.display_name,
          color: accountable.color,
          classification: classification,
          values_by_date: values_by_date
        }
      end
    end

    def grouped_accounts
      historical_accounts
        .group_by { |account| [ account.classification, Accountable.from_type(account.accountable_type) ] }
        .sort_by do |(classification, accountable), _accounts|
          [
            classification == "asset" ? 0 : 1,
            Accountable::TYPES.index(accountable.name) || Float::INFINITY
          ]
        end
    end

    def series_for(accounts, favorable_direction:, period:)
      Balance::ChartSeriesBuilder.new(
        account_ids: accounts.map(&:id),
        account_active_until_dates: disabled_account_active_until_dates(accounts),
        currency: family.currency,
        period: period,
        interval: INTERVAL,
        favorable_direction: favorable_direction
      ).balance_series
    end

    def historical_accounts
      @historical_accounts ||= BalanceSheet::HistoricalAccountScope.new(family, user: user).relation.to_a
    end

    def disabled_account_active_until_dates(accounts)
      accounts.each_with_object({}) do |account, dates|
        next unless account.disabled?

        disabled_on = (account.disabled_at || account.updated_at).to_date
        dates[account.id] = disabled_on - 1.day
      end
    end

    def cache_key(period)
      shares_version = user ? AccountShare.where(user: user).maximum(:updated_at)&.to_i : nil
      key = [
        "balance_sheet_net_worth_breakdown_series",
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
