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
      latest_snapshot_date = provider_holdings_scope.maximum(:date)
      return unless latest_snapshot_date.present?

      latest_security_ids = provider_security_ids_for(latest_snapshot_date)
      return latest_snapshot_date if latest_security_ids.blank?

      stable_dates = provider_holdings_scope
        .distinct
        .order(date: :desc)
        .pluck(:date)
        .take_while { |date| provider_security_ids_for(date) == latest_security_ids }

      stable_dates.last || latest_snapshot_date
    end

    def provider_security_ids_for(date)
      provider_holdings_scope.where(date: date).order(:security_id).pluck(:security_id)
    end
end
