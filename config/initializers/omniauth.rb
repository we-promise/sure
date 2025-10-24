# frozen_string_literal: true

require "omniauth/rails_csrf_protection"

# Configure OmniAuth for production or test environments
# In test mode, OmniAuth will use mock data instead of real provider configuration
if ENV["OIDC_ISSUER"].present? || Rails.env.test?
  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect,
             name: :openid_connect,
             scope: %i[openid email profile],
             response_type: :code,
             issuer: ENV["OIDC_ISSUER"] || "https://test.example.com",
             discovery: true,
             pkce: true,
             client_options: {
               identifier: ENV["OIDC_CLIENT_ID"] || "test_client_id",
               secret: ENV["OIDC_CLIENT_SECRET"] || "test_client_secret",
               redirect_uri: ENV["OIDC_REDIRECT_URI"] || "http://test.example.com/callback"
             }
  end
end
