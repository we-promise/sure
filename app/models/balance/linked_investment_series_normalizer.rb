class Balance::LinkedInvestmentSeriesNormalizer
  attr_reader :account, :series

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
