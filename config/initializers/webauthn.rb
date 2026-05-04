# frozen_string_literal: true

Rails.application.configure do
  config.x.webauthn = ActiveSupport::OrderedOptions.new

  credentials_config = Rails.application.credentials.webauthn || {}
  credential_rp_id = credentials_config[:rp_id] || credentials_config["rp_id"]
  credential_origins = credentials_config[:allowed_origins] || credentials_config["allowed_origins"]

  configured_rp_id = ENV["WEBAUTHN_RP_ID"].presence || credential_rp_id.presence || ENV["APP_DOMAIN"].presence
  default_rp_id = Rails.env.test? ? "www.example.com" : "localhost"

  rp_id = configured_rp_id.presence || default_rp_id
  rp_id = rp_id.to_s.strip.sub(%r{\Ahttps?://}, "").split("/").first.to_s.split(":").first

  configured_origins = ENV["WEBAUTHN_ALLOWED_ORIGINS"].presence || credential_origins
  allowed_origins = Array(configured_origins)
    .flat_map { |origin| origin.to_s.split(",") }
    .map { |origin| origin.strip.chomp("/") }
    .reject(&:blank?)

  if allowed_origins.blank?
    allowed_origins = if Rails.env.test?
      [ "http://www.example.com" ]
    elsif rp_id == "localhost"
      [ "http://localhost:3000" ]
    else
      [ "https://#{rp_id}" ]
    end
  end

  config.x.webauthn.rp_id = rp_id
  config.x.webauthn.allowed_origins = allowed_origins
end
