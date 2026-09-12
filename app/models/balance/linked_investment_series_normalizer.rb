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

  # Trims points before supported provider history and prepends an anchor point at inception
  # if coarse sampling missed the opening date within the requested period.
  def normalize
    return series unless account.linked? && account.balance_type == :investment

    first_supported_history_date = supported_history_start_date
    return series unless first_supported_history_date.present?

    active_points = series.values.select { |value| value.date >= first_supported_history_date }
    return series if active_points.blank?

    # If periodic sampling missed the exact opening date (e.g. coarse 1-month or 1-week intervals),
    # prepend an anchor point on the exact opening date with the initial balance (e.g. $0)
    # only when the inception date falls within the requested series date range.
    if first_supported_history_date >= series.start_date && active_points.first.date > first_supported_history_date
      currency = active_points.first.value.currency
      initial_amount = case view.to_sym
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
      opening_money = Money.new(initial_amount, currency)
      anchor_value = Series::Value.new(
        date: first_supported_history_date,
        date_formatted: I18n.l(first_supported_history_date, format: :long),
        value: opening_money,
        trend: Trend.new(
          current: opening_money,
          previous: nil,
          favorable_direction: series.favorable_direction
        )
      )
      active_points = [ anchor_value, *active_points ]
    end

    return series if active_points.first&.date == series.values.first&.date && active_points.length == series.values.length

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
