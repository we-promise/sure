class Balance::LinkedInvestmentSeriesNormalizer
  attr_reader :account, :series, :view

  class << self
    def aggregate_accounts(accounts:, currency:, period:, favorable_direction:, interval: "1 day")
      aggregate_account_ids(
        account_ids: Array(accounts).map(&:id),
        currency: currency,
        period: period,
        favorable_direction: favorable_direction,
        interval: interval
      )
    end

    def aggregate_account_ids(account_ids:, currency:, period:, favorable_direction:, interval: "1 day")
      account_ids = Array(account_ids).compact
      series = Balance::ChartSeriesBuilder.new(
        account_ids: account_ids,
        currency: currency,
        period: period,
        favorable_direction: favorable_direction,
        interval: interval
      ).balance_series

      common_start_date = common_supported_history_start_date(account_ids)
      return series unless common_start_date.present?

      trimmed_values = series.values.select { |value| value.date >= common_start_date }
      return series if trimmed_values.blank? || trimmed_values.length == series.values.length

      Series.new(
        start_date: trimmed_values.first.date,
        end_date: series.end_date,
        interval: series.interval,
        values: trimmed_values,
        favorable_direction: series.favorable_direction
      )
    end

    def supported_history_start_date(account)
      new(account: account, series: nil).supported_history_start_date
    end

    private
      def common_supported_history_start_date(account_ids)
        account_ids = Array(account_ids).compact
        return if account_ids.empty?

        activity_dates = Entry.where(account_id: account_ids)
          .excluding_pending
          .where.not(source: nil)
          .where.not(entryable_type: "Valuation")
          .group(:account_id)
          .minimum(:date)

        stable_holding_dates = stable_provider_holding_start_dates(account_ids)

        account_ids.filter_map do |account_id|
          [ activity_dates[account_id], stable_holding_dates[account_id] ].compact.min
        end.max
      end

      def stable_provider_holding_start_dates(account_ids)
        rows = Holding.where(account_id: account_ids)
          .where.not(account_provider_id: nil)
          .group(:account_id, :date)
          .order(account_id: :asc, date: :desc)
          .pluck(:account_id, :date, Arel.sql("array_agg(security_id ORDER BY security_id)"))

        rows.group_by(&:first).transform_values do |account_rows|
          _account_id, latest_snapshot_date, latest_security_ids = account_rows.first
          next unless latest_snapshot_date.present?
          next latest_snapshot_date if latest_security_ids.blank?

          stable_dates = account_rows
            .take_while { |_id, _date, security_ids| security_ids == latest_security_ids }
            .map { |_id, date, _security_ids| date }

          stable_dates.last || latest_snapshot_date
        end
      end
  end

  # Normalizes chart series for linked investment accounts by trimming unsupported
  # history and aligning the inception boundary.
  def initialize(account:, series:, view: :balance)
    @account = account
    @series = series
    @view = view
  end

  # Trims points before supported provider history and aligns the series
  # inception with the balance before the first provider activity, so a
  # deposit on the opening day reads as a change in value rather than as
  # the starting value.
  def normalize
    return series unless account.linked? && account.balance_type == :investment

    first_supported_history_date = supported_history_start_date
    return series unless first_supported_history_date.present?

    active_points = series.values.select { |value| value.date >= first_supported_history_date }
    return series if active_points.blank?

    opening_money = Money.new(opening_amount(first_supported_history_date), active_points.first.value.currency)

    if first_supported_history_date >= series.start_date && active_points.first.date > first_supported_history_date
      # Periodic sampling missed the exact opening date (e.g. coarse 1-month or
      # 1-week intervals): prepend an anchor point on the exact opening date with
      # the initial balance (e.g. $0), only when the inception date falls within
      # the requested series date range.
      active_points = [ opening_point(date: first_supported_history_date, date_formatted: nil, value: opening_money), *active_points ]
    elsif active_points.first.date == first_supported_history_date &&
          first_provider_activity_date == first_supported_history_date
      # Sampling landed exactly on the opening date (e.g. a daily "All" chart)
      # and that date is the first provider activity date: the first point
      # carries the day's closing balance, which already includes the first
      # activity. Reset it to the balance before that activity (#3959).
      # When the inception date comes from provider holdings rather than
      # activity, the first point is genuine supported history and is kept.
      first_point = active_points.first
      active_points = [
        opening_point(date: first_point.date, date_formatted: first_point.date_formatted, value: opening_money),
        *active_points.drop(1)
      ]
    end

    return series if unchanged?(active_points)

    Series.new(
      start_date: active_points.first.date,
      end_date: series.end_date,
      interval: series.interval,
      values: active_points,
      favorable_direction: series.favorable_direction
    )
  end

  def supported_history_start_date
    [ first_provider_activity_date, stable_provider_holding_start_date ].compact.min
  end

  private

    # The balance just before the first provider activity: 0 for views that
    # measure change (gains, holdings), the opening anchor balance for balance
    # views when the anchor marks the inception date, 0 otherwise.
    def opening_amount(first_supported_history_date)
      case view.to_sym
      when :gains, :holdings_balance
        0
      when :cash_balance, :balance
        if account.has_opening_anchor? && first_supported_history_date == account.opening_anchor_date
          account.opening_anchor_balance || 0
        else
          0
        end
      else
        0
      end
    end

    def opening_point(date:, date_formatted:, value:)
      Series::Value.new(
        date: date,
        date_formatted: date_formatted || I18n.l(date, format: :long),
        value: value,
        trend: Trend.new(
          current: value,
          previous: nil,
          favorable_direction: series.favorable_direction
        )
      )
    end

    # The series is untouched when trimming and inception alignment changed
    # neither the dates nor the values of the points.
    def unchanged?(active_points)
      active_points.first&.date == series.values.first&.date &&
        active_points.length == series.values.length &&
        active_points.first&.value == series.values.first&.value
    end

    def first_provider_activity_date
      @first_provider_activity_date ||= account.entries
        .excluding_pending
        .where.not(source: nil)
        .where.not(entryable_type: "Valuation")
        .minimum(:date)
    end

    def provider_holdings_scope
      @provider_holdings_scope ||= account.holdings.where.not(account_provider_id: nil)
    end

    def stable_provider_holding_start_date
      date_security_pairs = provider_holdings_scope
        .group(:date)
        .order(date: :desc)
        .pluck(:date, Arel.sql("array_agg(security_id ORDER BY security_id)"))
      latest_snapshot_date, latest_security_ids = date_security_pairs.first
      return unless latest_snapshot_date.present?
      return latest_snapshot_date if latest_security_ids.blank?

      stable_dates = date_security_pairs
        .take_while { |_date, security_ids| security_ids == latest_security_ids }
        .map(&:first)

      stable_dates.last || latest_snapshot_date
    end
end
