class Balance::LinkedInvestmentSeriesNormalizer
  attr_reader :account, :series

  class << self
    def aggregate_accounts(accounts:, currency:, period:, favorable_direction:, interval: "1 day")
      accounts = Array(accounts)
      account_ids = accounts.map(&:id)

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

    private
      def common_supported_history_start_date(account_ids)
        account_ids = Array(account_ids).compact
        return if account_ids.empty?

        activity_dates = Entry.where(account_id: account_ids)
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

  def initialize(account:, series:)
    @account = account
    @series = series
  end

  def normalize
    return series unless account.linked? && account.balance_type == :investment

    first_supported_history_date = supported_history_start_date
    return series unless first_supported_history_date.present?

    trimmed_values = series.values.select { |value| value.date >= first_supported_history_date }
    return series if trimmed_values.blank? || trimmed_values.length == series.values.length

    Series.new(
      start_date: trimmed_values.first.date,
      end_date: series.end_date,
      interval: series.interval,
      values: trimmed_values,
      favorable_direction: series.favorable_direction
    )
  end

  private

    def supported_history_start_date
      [ first_provider_activity_date, stable_provider_holding_start_date ].compact.min
    end

    def first_provider_activity_date
      @first_provider_activity_date ||= account.entries
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
