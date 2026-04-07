class Settings::Hostings::InflationProvidersSettingsComponent < ApplicationComponent
  attr_reader :us_bls_cpi_base_url,
              :us_bls_cpi_series_id,
              :es_ine_cpi_base_url,
              :es_ine_cpi_series_id,
              :env_us_bls_cpi_base_url,
              :env_us_bls_cpi_series_id,
              :env_es_ine_cpi_base_url,
              :env_es_ine_cpi_series_id

  def initialize(
    us_bls_cpi_base_url:,
    us_bls_cpi_series_id:,
    es_ine_cpi_base_url:,
    es_ine_cpi_series_id:,
    env_us_bls_cpi_base_url:,
    env_us_bls_cpi_series_id:,
    env_es_ine_cpi_base_url:,
    env_es_ine_cpi_series_id:
  )
    @us_bls_cpi_base_url = us_bls_cpi_base_url
    @us_bls_cpi_series_id = us_bls_cpi_series_id
    @es_ine_cpi_base_url = es_ine_cpi_base_url
    @es_ine_cpi_series_id = es_ine_cpi_series_id
    @env_us_bls_cpi_base_url = env_us_bls_cpi_base_url
    @env_us_bls_cpi_series_id = env_us_bls_cpi_series_id
    @env_es_ine_cpi_base_url = env_es_ine_cpi_base_url
    @env_es_ine_cpi_series_id = env_es_ine_cpi_series_id
  end

  def us_bls_base_url_effective
    env_us_bls_cpi_base_url.presence || us_bls_cpi_base_url
  end

  def us_bls_series_id_effective
    env_us_bls_cpi_series_id.presence || us_bls_cpi_series_id
  end

  def es_ine_base_url_effective
    env_es_ine_cpi_base_url.presence || es_ine_cpi_base_url
  end

  def es_ine_series_id_effective
    env_es_ine_cpi_series_id.presence || es_ine_cpi_series_id
  end

  def us_bls_base_url_locked?
    env_us_bls_cpi_base_url.present?
  end

  def us_bls_series_id_locked?
    env_us_bls_cpi_series_id.present?
  end

  def es_ine_base_url_locked?
    env_es_ine_cpi_base_url.present?
  end

  def es_ine_series_id_locked?
    env_es_ine_cpi_series_id.present?
  end
end
