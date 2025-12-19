# frozen_string_literal: true

require "omniauth/rails_csrf_protection"

Rails.configuration.x.auth.oidc_enabled = false
Rails.configuration.x.auth.sso_providers ||= []

Rails.application.config.middleware.use OmniAuth::Builder do
  (Rails.configuration.x.auth.providers || []).each do |raw_cfg|
    cfg = raw_cfg.deep_symbolize_keys
    strategy = cfg[:strategy].to_s
    name = (cfg[:name] || cfg[:id]).to_s

    case strategy
    when "openid_connect"
      required_env = %w[OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_REDIRECT_URI]
      enabled = Rails.env.test? || required_env.all? { |k| ENV[k].present? }
      next unless enabled

      issuer = (ENV["OIDC_ISSUER"].presence || "https://test.example.com").to_s.strip
      client_id = ENV["OIDC_CLIENT_ID"].presence || "test_client_id"
      client_secret = ENV["OIDC_CLIENT_SECRET"].presence || "test_client_secret"
      redirect_uri = ENV["OIDC_REDIRECT_URI"].presence || "http://test.example.com/callback"

      provider :openid_connect,
               name: name.to_sym,
               scope: %i[openid email profile],
               response_type: :code,
               issuer: issuer,
               discovery: true,
               pkce: true,
               client_options: {
                 identifier: client_id,
                 secret: client_secret,
                 redirect_uri: redirect_uri
               }

      Rails.configuration.x.auth.oidc_enabled = true
      Rails.configuration.x.auth.sso_providers << cfg.merge(name: name)

    when "google_oauth2"
      client_id = ENV["GOOGLE_OAUTH_CLIENT_ID"].presence || (Rails.env.test? ? "test_client_id" : nil)
      client_secret = ENV["GOOGLE_OAUTH_CLIENT_SECRET"].presence || (Rails.env.test? ? "test_client_secret" : nil)
      next unless client_id.present? && client_secret.present?

      provider :google_oauth2,
               client_id,
               client_secret,
               {
                 name: name.to_sym,
                 scope: "userinfo.email,userinfo.profile"
               }

      Rails.configuration.x.auth.sso_providers << cfg.merge(name: name)

    when "github"
      client_id = ENV["GITHUB_CLIENT_ID"].presence || (Rails.env.test? ? "test_client_id" : nil)
      client_secret = ENV["GITHUB_CLIENT_SECRET"].presence || (Rails.env.test? ? "test_client_secret" : nil)
      next unless client_id.present? && client_secret.present?

      provider :github,
               client_id,
               client_secret,
               {
                 name: name.to_sym,
                 scope: "user:email"
               }

      Rails.configuration.x.auth.sso_providers << cfg.merge(name: name)
    end
  end
end

if Rails.configuration.x.auth.sso_providers.empty?
  Rails.logger.warn("No SSO providers enabled; check auth.yml / ENV configuration")
end
