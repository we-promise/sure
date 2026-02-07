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
  # Load providers from either YAML or DB via ProviderLoader
  providers = ProviderLoader.load_providers

  providers.each do |raw_cfg|
    cfg = raw_cfg.deep_symbolize_keys
    strategy = cfg[:strategy].to_s
    name = (cfg[:name] || cfg[:id]).to_s

    case strategy
    when "openid_connect"
      # Support per-provider credentials from config or fall back to global ENV vars
      issuer = cfg[:issuer].presence || ENV["OIDC_ISSUER"].presence
      client_id = cfg[:client_id].presence || ENV["OIDC_CLIENT_ID"].presence
      client_secret = cfg[:client_secret].presence || ENV["OIDC_CLIENT_SECRET"].presence
      redirect_uri = cfg[:redirect_uri].presence || ENV["OIDC_REDIRECT_URI"].presence

      # In test environment, use test values if nothing is configured
      if Rails.env.test?
        issuer ||= "https://test.example.com"
        client_id ||= "test_client_id"
        client_secret ||= "test_client_secret"
        redirect_uri ||= "http://test.example.com/callback"
      end

      # Skip if required fields are missing (except in test)
      unless issuer.present? && client_id.present? && client_secret.present? && redirect_uri.present?
        Rails.logger.warn("[OmniAuth] Skipping OIDC provider '#{name}' - missing required configuration")
        next
      end

      # Custom scopes: parse from settings if provided, otherwise use defaults
      custom_scopes = cfg.dig(:settings, :scopes).presence
      scopes = if custom_scopes.present?
        custom_scopes.to_s.split(/\s+/).map(&:to_sym)
      else
        %i[openid email profile]
      end

      # Build provider options
      oidc_options = {
        name: name.to_sym,
        scope: scopes,
        response_type: :code,
        issuer: issuer.to_s.strip,
        discovery: true,
        pkce: true,
        client_options: {
          identifier: client_id,
          secret: client_secret,
          redirect_uri: redirect_uri,
          ssl: begin
                 ssl_config = Rails.configuration.x.ssl
                 ssl_opts = {}
                 ssl_opts[:ca_file] = ssl_config.ca_file if ssl_config&.ca_file.present?
                 ssl_opts[:verify] = false if ssl_config&.verify == false
                 ssl_opts
               end
        }
      }

      # Add prompt parameter if configured
      prompt = cfg.dig(:settings, :prompt).presence
      oidc_options[:prompt] = prompt if prompt.present?

      provider :openid_connect, oidc_options

      Rails.configuration.x.auth.oidc_enabled = true
      Rails.configuration.x.auth.sso_providers << cfg.merge(name: name, issuer: issuer)

    when "google_oauth2"
      client_id = cfg[:client_id].presence || ENV["GOOGLE_OAUTH_CLIENT_ID"].presence
      client_secret = cfg[:client_secret].presence || ENV["GOOGLE_OAUTH_CLIENT_SECRET"].presence

      # Test environment fallback
      if Rails.env.test?
        client_id ||= "test_client_id"
        client_secret ||= "test_client_secret"
      end

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
      client_id = cfg[:client_id].presence || ENV["GITHUB_CLIENT_ID"].presence
      client_secret = cfg[:client_secret].presence || ENV["GITHUB_CLIENT_SECRET"].presence

      # Test environment fallback
      if Rails.env.test?
        client_id ||= "test_client_id"
        client_secret ||= "test_client_secret"
      end

      next unless client_id.present? && client_secret.present?

      provider :github,
               client_id,
               client_secret,
               {
                 name: name.to_sym,
                 scope: "user:email"
               }

      Rails.configuration.x.auth.sso_providers << cfg.merge(name: name)

    when "saml"
      settings = cfg[:settings] || {}

      # Require either metadata URL or manual SSO URL
      idp_metadata_url = settings[:idp_metadata_url].presence || settings["idp_metadata_url"].presence
      idp_sso_url = settings[:idp_sso_url].presence || settings["idp_sso_url"].presence

      unless idp_metadata_url.present? || idp_sso_url.present?
        Rails.logger.warn("[OmniAuth] Skipping SAML provider '#{name}' - missing IdP configuration")
        next
      end

      # Build SAML options
      saml_options = {
        name: name.to_sym,
        assertion_consumer_service_url: cfg[:redirect_uri].presence || "#{ENV['APP_URL']}/auth/#{name}/callback",
        issuer: cfg[:issuer].presence || ENV["APP_URL"],
        name_identifier_format: settings[:name_id_format].presence || settings["name_id_format"].presence ||
                               "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
        attribute_statements: {
          email: [ "email", "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress" ],
          first_name: [ "first_name", "givenName", "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname" ],
          last_name: [ "last_name", "surname", "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname" ],
          groups: [ "groups", "http://schemas.microsoft.com/ws/2008/06/identity/claims/groups" ]
        }
      }

      # Use metadata URL or manual configuration
      if idp_metadata_url.present?
        saml_options[:idp_metadata_url] = idp_metadata_url
      else
        saml_options[:idp_sso_service_url] = idp_sso_url
        saml_options[:idp_cert] = settings[:idp_certificate].presence || settings["idp_certificate"].presence
        saml_options[:idp_cert_fingerprint] = settings[:idp_cert_fingerprint].presence || settings["idp_cert_fingerprint"].presence
      end

      # Optional: IdP SLO (Single Logout) URL
      idp_slo_url = settings[:idp_slo_url].presence || settings["idp_slo_url"].presence
      saml_options[:idp_slo_service_url] = idp_slo_url if idp_slo_url.present?

      provider :saml, saml_options

      Rails.configuration.x.auth.sso_providers << cfg.merge(name: name, strategy: "saml")
    end
  end

  if Rails.configuration.x.auth.sso_providers.empty?
    Rails.logger.warn("No SSO providers enabled; check auth.yml / ENV configuration or database providers")
  end
end
