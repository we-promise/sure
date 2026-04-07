module Bond::InflationProvider
  InflationRecord = Data.define(:year, :month, :rate_yoy)

  PROVIDERS = {
    "gus_sdp" => "Provider::GusSdp",
    "us_bls" => "Provider::UsBlsCpi",
    "es_ine" => "Provider::EsIneCpi"
  }.freeze

  module_function

  def valid?(provider)
    provider.blank? || PROVIDERS.key?(provider)
  end

  def key_for(provider)
    provider.presence || "gus_sdp"
  end

  def record_for_date(provider:, date:, lag_months: 0, allow_import: true)
    provider_key = key_for(provider)
    return nil unless PROVIDERS.key?(provider_key)

    if provider_key == "gus_sdp"
      record = GusInflationRate.for_date(date: date, lag_months: lag_months)
      return nil if record.nil?
      return InflationRecord.new(year: record.year, month: record.month, rate_yoy: record.rate_yoy)
    end

    target_date = date.beginning_of_month - lag_months.to_i.months
    source_key = provider_key
    persisted = InflationRate.for_date(source: source_key, date: date, lag_months: lag_months)
    if persisted.present?
      return InflationRecord.new(year: persisted.year, month: persisted.month, rate_yoy: persisted.rate_yoy)
    end
    return nil unless allow_import

    provider_klass = provider_class(provider_key)
    return nil if provider_klass.blank?

    InflationRate.import_year!(
      source: source_key,
      provider: provider_klass.new,
      year: target_date.year
    )

    result = InflationRate.for_date(source: source_key, date: date, lag_months: lag_months)
    return nil if result.nil?
    InflationRecord.new(year: result.year, month: result.month, rate_yoy: result.rate_yoy)
  rescue Faraday::Error, Provider::Error, ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[Bond::InflationProvider] record_for_date failed: #{e.class} - #{e.message}")
    nil
  end

  def provider_class(provider)
    klass_name = PROVIDERS[key_for(provider)]
    return nil if klass_name.blank?

    klass_name.constantize
  end
end
