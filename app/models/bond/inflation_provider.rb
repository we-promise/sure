module Bond::InflationProvider
  InflationRecord = Data.define(:year, :month, :rate_yoy)
  DEFAULT_PROVIDER_BY_LOCALE = {
    "pl" => "gus_sdp",
    "es" => "es_ine",
    "en" => "us_bls",
    "us" => "us_bls",
    "en-us" => "us_bls"
  }.freeze

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

  def default_provider_for(account: nil, bond: nil, lot: nil, product_code: nil, locale: nil)
    resolved_product_code = product_code.presence || lot&.product_code
    provider_for_product_code(resolved_product_code) ||
      provider_for_locale(locale.presence || lot_locale(lot:, bond:, account:)) ||
      "gus_sdp"
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
  rescue Faraday::Error, Provider::Error, ActiveRecord::RecordInvalid, RuntimeError => e
    Rails.logger.warn("[Bond::InflationProvider] record_for_date failed: #{e.class} - #{e.message}")
    nil
  end

  # automatic_import_enabled? intentionally differs by key_for(provider):
  # - "gus_sdp" respects Setting.inflation_import_enabled_effective
  # - "es_ine" requires configured es_ine_series_id
  # - "us_bls" is always enabled because it uses public defaults and needs no tenant-specific setup
  def automatic_import_enabled?(provider)
    case key_for(provider)
    when "gus_sdp"
      Setting.inflation_import_enabled_effective
    when "es_ine"
      es_ine_series_id.present?
    when "us_bls"
      true
    else
      false
    end
  end

  def stats_for(provider)
    provider_key = key_for(provider)

    if provider_key == "gus_sdp"
      GusInflationRate.stats
    else
      InflationRate.stats_for(source: provider_key)
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

  def provider_for_product_code(product_code)
    return nil if product_code.blank?

    Bond::PRODUCT_DEFAULTS.dig(product_code, :inflation_provider) ||
      case product_code.to_s
      when /^pl_/
        "gus_sdp"
      when /^us_/
        "us_bls"
      when /^es_/
        "es_ine"
      end
  end

  def provider_for_locale(locale)
    normalized_locale = locale.to_s.strip.downcase
    return nil if normalized_locale.blank?

    DEFAULT_PROVIDER_BY_LOCALE[normalized_locale] ||
      DEFAULT_PROVIDER_BY_LOCALE[normalized_locale.split(/[_-]/).first]
  end

  def lot_locale(lot:, bond:, account:)
    lot&.account&.family&.locale.presence ||
      bond&.account&.family&.locale.presence ||
      account&.family&.locale.presence ||
      Current.family&.locale.presence ||
      Current.user&.family&.locale.presence ||
      I18n.locale
  end
end
