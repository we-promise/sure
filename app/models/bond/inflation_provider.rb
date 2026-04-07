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

    source_key = provider_key
    persisted = InflationRate.for_date(source: source_key, date: date, lag_months: lag_months)
    if persisted.present?
      return InflationRecord.new(year: persisted.year, month: persisted.month, rate_yoy: persisted.rate_yoy)
    end
    return nil unless allow_import
    return nil if provider_key == "es_ine" && es_ine_series_id.blank?

    provider_klass = provider_class(provider_key)
    provider_instance = provider_instance_for(provider_key, provider_klass)
    return nil if provider_instance.blank?

    target_date = date.beginning_of_month - lag_months.to_i.months
    InflationRate.import_year!(
      source: source_key,
      provider: provider_instance,
      year: target_date.year
    )

    result = InflationRate.for_date(source: source_key, date: date, lag_months: lag_months)
    return nil if result.nil?
    InflationRecord.new(year: result.year, month: result.month, rate_yoy: result.rate_yoy)
  rescue Faraday::Error, Provider::Error, ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[Bond::InflationProvider] record_for_date failed: #{e.class} - #{e.message}")
    nil
  end

  def automatic_import_enabled?(provider)
    case key_for(provider)
    when "gus_sdp"
      Setting.gus_inflation_import_enabled_effective
    when "es_ine"
      es_ine_series_id.present?
    when "us_bls"
      true
    else
      false
    end
  end

  def provider_class(provider)
    klass_name = PROVIDERS[key_for(provider)]
    return nil if klass_name.blank?

    klass_name.constantize
  end

  def provider_instance_for(provider_key, provider_klass)
    return nil if provider_klass.blank?

    case provider_key
    when "us_bls"
      provider_klass.new(
        base_url: ENV["US_BLS_CPI_BASE_URL"].presence || Setting.us_bls_cpi_base_url.presence || Provider::UsBlsCpi::DEFAULT_BASE_URL,
        series_id: ENV["US_BLS_CPI_SERIES_ID"].presence || Setting.us_bls_cpi_series_id.presence || Provider::UsBlsCpi::DEFAULT_SERIES_ID
      )
    when "es_ine"
      provider_klass.new(
        base_url: ENV["ES_INE_CPI_BASE_URL"].presence || Setting.es_ine_cpi_base_url.presence || Provider::EsIneCpi::DEFAULT_BASE_URL,
        series_id: ENV["ES_INE_CPI_SERIES_ID"].presence || Setting.es_ine_cpi_series_id.presence
      )
    else
      provider_klass.new
    end
  end

  def es_ine_series_id
    ENV["ES_INE_CPI_SERIES_ID"].presence || Setting.es_ine_cpi_series_id.presence
  end
end
