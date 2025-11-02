# frozen_string_literal: true

require "omniauth/rails_csrf_protection"

# Configure OmniAuth for production or test environments
# In test mode, OmniAuth will use mock data instead of real provider configuration
required_env = %w[OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_REDIRECT_URI]
missing = required_env.select { |k| ENV[k].blank? }
if missing.empty? || Rails.env.test?
  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect,
             name: :openid_connect,
             scope: %i[openid email profile],
             response_type: :code,
             issuer: ENV["OIDC_ISSUER"].to_s.strip || "https://test.example.com",
             discovery: true,
             pkce: true,
             client_options: {
               identifier: ENV["OIDC_CLIENT_ID"] || "test_client_id",
               secret: ENV["OIDC_CLIENT_SECRET"] || "test_client_secret",
               redirect_uri: ENV["OIDC_REDIRECT_URI"] || "http://test.example.com/callback"
             }
  end
  Rails.configuration.x.auth.oidc_enabled = true
else
  Rails.logger.warn("OIDC not enabled: missing env vars: #{missing.join(', ')}")
  Rails.configuration.x.auth.oidc_enabled = false
end
