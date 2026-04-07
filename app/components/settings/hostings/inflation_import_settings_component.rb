class Settings::Hostings::InflationImportSettingsComponent < ApplicationComponent
  PROVIDERS = %w[gus_sdp us_bls es_ine].freeze

  attr_reader :inflation_import_enabled_effective,
              :env_inflation_import_enabled,
              :last_import_at,
              :last_import_range,
              :last_import_count,
              :last_import_error,
              :provider_stats,
              :last_import_details,
              :current_year

  def initialize(
    inflation_import_enabled_effective:,
    env_inflation_import_enabled:,
    last_import_at:,
    last_import_range:,
    last_import_count:,
    last_import_error:,
    provider_stats:,
    last_import_details:,
    current_year:
  )
    @inflation_import_enabled_effective = inflation_import_enabled_effective
    @env_inflation_import_enabled = env_inflation_import_enabled
    @last_import_at = last_import_at
    @last_import_range = last_import_range
    @last_import_count = last_import_count
    @last_import_error = last_import_error
    @provider_stats = provider_stats || {}
    @last_import_details = last_import_details || {}
    @current_year = current_year
  end

  def import_toggle_locked_by_env?
    env_inflation_import_enabled.present?
  end

  def start_year_default
    current_year - 20
  end

  def end_year_default
    current_year - 1
  end

  def provider_rows
    PROVIDERS.map do |provider_key|
      stats = provider_stats[provider_key] || {}
      {
        key: provider_key,
        title: provider_title(provider_key),
        imported_count: last_import_details[provider_key],
        stored_count: stats[:count].to_i,
        stored_range: stats_range(stats)
      }
    end
  end

  def value_or_dash(value)
    value.present? ? value : "-"
  end

  private
    def provider_title(provider_key)
      case provider_key
      when "gus_sdp"
        I18n.t("settings.hostings.gus_sdp_settings.title")
      when "us_bls"
        I18n.t("settings.hostings.inflation_providers_settings.us_bls_title")
      when "es_ine"
        I18n.t("settings.hostings.inflation_providers_settings.es_ine_title")
      end
    end

    def stats_range(stats)
      return nil if stats[:count].to_i <= 0
      return nil if stats[:min_year].blank? || stats[:max_year].blank?

      "#{stats[:min_year]}-#{stats[:max_year]}"
    end
end
