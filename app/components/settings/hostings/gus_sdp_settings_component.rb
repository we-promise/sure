class Settings::Hostings::GusSdpSettingsComponent < ApplicationComponent
  attr_reader :gus_sdp_api_key,
              :env_gus_sdp_api_key

  def initialize(
    gus_sdp_api_key:,
    env_gus_sdp_api_key:
  )
    @gus_sdp_api_key = gus_sdp_api_key
    @env_gus_sdp_api_key = env_gus_sdp_api_key
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

  def api_key_input_unlocked?
    !env_api_key_configured?
  end

end
