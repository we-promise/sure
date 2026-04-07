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

  def record_for_date(provider:, date:, lag_months: 0)
    provider_key = key_for(provider)
    return nil unless PROVIDERS.key?(provider_key)

    if provider_key == "gus_sdp"
      return GusInflationRate.for_date(date: date, lag_months: lag_months)
    end

    target_date = date.beginning_of_month - lag_months.to_i.months
    response = provider_class(provider_key).new.fetch_cpi_yoy_for_year(year: target_date.year)
    return nil unless response.success?

    month_data = response.data.find { |row| row[:month].to_i == target_date.month }
    return nil if month_data.blank?

    InflationRecord.new(
      year: target_date.year,
      month: target_date.month,
      rate_yoy: month_data[:rate_yoy].to_d
    )
  end

  def provider_class(provider)
    klass_name = PROVIDERS[key_for(provider)]
    return nil if klass_name.blank?

    klass_name.constantize
  end
end
