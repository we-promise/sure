# frozen_string_literal: true

require "omniauth/rails_csrf_protection"

Rails.configuration.x.auth.oidc_enabled = false
Rails.configuration.x.auth.sso_providers ||= []

# Configure OmniAuth to handle failures gracefully
OmniAuth.config.on_failure = proc do |env|
  error = env["omniauth.error"]
  error_type = env["omniauth.error.type"]
  strategy = env["omniauth.error.strategy"]

  # Log the error for debugging
  Rails.logger.error("[OmniAuth] Authentication failed: #{error_type} - #{error&.message}")

  # Redirect to failure handler with error info
  message = case error_type
  when :discovery_failed, :invalid_credentials
    "sso_provider_unavailable"
  when :invalid_response
    "sso_invalid_response"
  else
    "sso_failed"
  end

  Rack::Response.new([ "302 Moved" ], 302, "Location" => "/auth/failure?message=#{message}&strategy=#{strategy&.name}").finish
end

Rails.application.config.middleware.use OmniAuth::Builder do
  OmniauthProviderRegistry.register_dynamic_database_oidc_provider(self)

  # Load providers from either YAML or DB via ProviderLoader
  providers = ProviderLoader.load_providers

  providers.each do |raw_cfg|
    config = OmniauthProviderRegistry.register(self, raw_cfg)
    next unless config

    Rails.configuration.x.auth.oidc_enabled = true if config[:strategy].to_s == "openid_connect"
    Rails.configuration.x.auth.sso_providers << config
  end

  if Rails.configuration.x.auth.sso_providers.empty?
    Rails.logger.warn("No SSO providers enabled; check auth.yml / ENV configuration or database providers")
  end
end
