class Settings::Hostings::GusSdpSettingsComponent < ApplicationComponent
  attr_reader :inflation_import_enabled_effective,
              :gus_sdp_api_key,
              :env_gus_sdp_api_key,
              :env_gus_inflation_import_enabled,
              :gus_stats,
              :last_import_at,
              :last_import_range,
              :last_import_count,
              :last_import_error,
              :current_year

  def initialize(
    inflation_import_enabled_effective:,
    gus_sdp_api_key:,
    env_gus_sdp_api_key:,
    env_gus_inflation_import_enabled:,
    gus_stats:,
    last_import_at:,
    last_import_range:,
    last_import_count:,
    last_import_error:,
    current_year:
  )
    @inflation_import_enabled_effective = inflation_import_enabled_effective
    @gus_sdp_api_key = gus_sdp_api_key
    @env_gus_sdp_api_key = env_gus_sdp_api_key
    @env_gus_inflation_import_enabled = env_gus_inflation_import_enabled
    @gus_stats = gus_stats
    @last_import_at = last_import_at
    @last_import_range = last_import_range
    @last_import_count = last_import_count
    @last_import_error = last_import_error
    @current_year = current_year
  end

  def env_api_key_configured?
    env_gus_sdp_api_key.present?
  end

  def db_api_key_configured?
    gus_sdp_api_key.present?
  end

  def show_clear_api_key_button?
    !env_api_key_configured? && db_api_key_configured?
  end

  def import_toggle_locked_by_env?
    env_gus_inflation_import_enabled.present?
  end

  def api_key_input_unlocked?
    !env_api_key_configured?
  end

  def start_year_default
    current_year - 20
  end

  def end_year_default
    current_year - 1
  end

  def stats_count
    gus_stats[:count].to_i
  end

  def stats_min_year
    gus_stats[:min_year]
  end

  def stats_max_year
    gus_stats[:max_year]
  end

  def stats_range?
    stats_count.positive?
  end
end
