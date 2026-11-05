# frozen_string_literal: true

class OmniauthProviderRegistry
  Registration = Struct.new(:strategy, :args, :options, :config, keyword_init: true)

  class << self
    # Register static strategies while leaving live database OIDC routing to the dynamic strategy.
    def register(builder, raw_cfg)
      registration = registration_for(raw_cfg)
      return unless registration

      # Live database OIDC names are handled exclusively by the dynamic strategy.
      # A boot-time copy would keep intercepting routes after disablement.
      if FeatureFlags.db_sso_providers? && registration.strategy == :openid_connect
        return registration.config
      end

      builder.provider registration.strategy, *registration.args, registration.options
      registration.config
    end

    # Normalize provider keys and build options for a supported authentication strategy.
    def registration_for(raw_cfg)
      cfg = raw_cfg.deep_symbolize_keys
      strategy = cfg[:strategy].to_s

      case strategy
      when "openid_connect"
        openid_connect_registration(cfg)
      when "google_oauth2"
        google_oauth2_registration(cfg)
      when "github"
        github_registration(cfg)
      when "saml"
        saml_registration(cfg)
      end
    end

    # Register one OIDC strategy that resolves enabled database providers at request time.
    def register_dynamic_database_oidc_provider(builder)
      builder.provider :openid_connect, dynamic_database_oidc_options
    end

    private
      # Build validated OIDC options and preserve the provider name and issuer.
      def openid_connect_registration(cfg)
        name = provider_name(cfg)
        oidc_options = Oidc::ProviderOptionsBuilder.call(cfg)

        unless oidc_options.present?
          Rails.logger.warn("[OmniAuth] Skipping OIDC provider '#{name}' - missing required configuration")
          return nil
        end

        Registration.new(
          strategy: :openid_connect,
          args: [],
          options: oidc_options,
          config: cfg.merge(name: name, issuer: oidc_options[:issuer])
        )
      end

      # Build a named Google OAuth strategy when client credentials are available.
      def google_oauth2_registration(cfg)
        name = provider_name(cfg)
        client_id = cfg[:client_id].presence || ENV["GOOGLE_OAUTH_CLIENT_ID"].presence
        client_secret = cfg[:client_secret].presence || ENV["GOOGLE_OAUTH_CLIENT_SECRET"].presence

        if Rails.env.test?
          client_id ||= "test_client_id"
          client_secret ||= "test_client_secret"
        end

        return unless client_id.present? && client_secret.present?

        Registration.new(
          strategy: :google_oauth2,
          args: [ client_id, client_secret ],
          options: {
            name: name.to_sym,
            scope: "userinfo.email,userinfo.profile"
          },
          config: cfg.merge(name: name)
        )
      end

      # Build a named GitHub OAuth strategy when client credentials are available.
      def github_registration(cfg)
        name = provider_name(cfg)
        client_id = cfg[:client_id].presence || ENV["GITHUB_CLIENT_ID"].presence
        client_secret = cfg[:client_secret].presence || ENV["GITHUB_CLIENT_SECRET"].presence

        if Rails.env.test?
          client_id ||= "test_client_id"
          client_secret ||= "test_client_secret"
        end

        return unless client_id.present? && client_secret.present?

        Registration.new(
          strategy: :github,
          args: [ client_id, client_secret ],
          options: {
            name: name.to_sym,
            scope: "user:email"
          },
          config: cfg.merge(name: name)
        )
      end

      # Build a named SAML strategy with its configured identity-provider endpoints.
      def saml_registration(cfg)
        name = provider_name(cfg)
        settings = cfg[:settings] || {}

        idp_metadata_url = settings[:idp_metadata_url].presence || settings["idp_metadata_url"].presence
        idp_sso_url = settings[:idp_sso_url].presence || settings["idp_sso_url"].presence

        unless idp_metadata_url.present? || idp_sso_url.present?
          Rails.logger.warn("[OmniAuth] Skipping SAML provider '#{name}' - missing IdP configuration")
          return
        end

        options = {
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

        if idp_metadata_url.present?
          options[:idp_metadata_url] = idp_metadata_url
        else
          options[:idp_sso_service_url] = idp_sso_url
          options[:idp_cert] = settings[:idp_certificate].presence || settings["idp_certificate"].presence
          options[:idp_cert_fingerprint] = settings[:idp_cert_fingerprint].presence || settings["idp_cert_fingerprint"].presence
        end

        idp_slo_url = settings[:idp_slo_url].presence || settings["idp_slo_url"].presence
        options[:idp_slo_service_url] = idp_slo_url if idp_slo_url.present?

        Registration.new(
          strategy: :saml,
          args: [],
          options: options,
          config: cfg.merge(name: name, strategy: "saml")
        )
      end

      # Use live route predicates and per-request setup for database-backed OIDC.
      def dynamic_database_oidc_options
        {
          name: :db_openid_connect,
          request_path: method(:database_oidc_request_path?),
          callback_path: method(:database_oidc_callback_path?),
          setup: method(:setup_database_oidc_provider)
        }.merge(openid_connect_options({}, "db_openid_connect", nil, nil, nil, nil))
      end

      # Accept an enabled database OIDC login route, excluding callbacks.
      def database_oidc_request_path?(env)
        database_oidc_config_for(env).present? && !callback_request?(env)
      end

      # Accept a callback only for a currently enabled database OIDC provider.
      def database_oidc_callback_path?(env)
        database_oidc_config_for(env).present? && callback_request?(env)
      end

      # Apply the selected live provider options to the request strategy.
      def setup_database_oidc_provider(env)
        registration = database_oidc_registration_for(env)
        return unless registration

        strategy = env["omniauth.strategy"]
        strategy.options.deep_merge!(registration.options)
      end

      # Return the selected request-scoped database provider configuration.
      def database_oidc_config_for(env)
        database_oidc_registration_for(env)&.config
      end

      # Resolve an enabled provider once per request without retaining stale boot-time routes.
      def database_oidc_registration_for(env)
        return unless FeatureFlags.db_sso_providers?
        return env["sure.omniauth.database_oidc_registration"] if env.key?("sure.omniauth.database_oidc_registration")

        name = auth_path_provider_name(env)
        return env["sure.omniauth.database_oidc_registration"] = nil if name.blank? || name == "failure" || name == "logout"

        ProviderLoader.load_providers.each do |raw_provider|
          provider = raw_provider.deep_symbolize_keys
          next unless provider[:strategy].to_s == "openid_connect" && provider[:name].to_s == name

          return env["sure.omniauth.database_oidc_registration"] = openid_connect_registration(provider)
        end

        env["sure.omniauth.database_oidc_registration"] = nil
      end

      # Extract a provider name only from a supported OmniAuth login or callback path.
      def auth_path_provider_name(env)
        path = env["PATH_INFO"].to_s
        match = path.match(%r{\A/auth/([^/]+)(?:/callback)?\z})
        match&.[](1)
      end

      # Distinguish callback requests from authentication-start requests.
      def callback_request?(env)
        env["PATH_INFO"].to_s.end_with?("/callback")
      end

      # Build common OIDC discovery, PKCE, scope and client options.
      def openid_connect_options(cfg, name, issuer, client_id, client_secret, redirect_uri)
        options = {
          name: name.to_sym,
          scope: openid_connect_scopes(cfg),
          response_type: :code,
          issuer: issuer.to_s.strip,
          discovery: true,
          pkce: true,
          client_options: {
            identifier: client_id,
            secret: client_secret,
            redirect_uri: redirect_uri,
            ssl: ssl_options
          }
        }

        prompt = cfg.dig(:settings, :prompt).presence || cfg.dig(:settings, "prompt").presence
        options[:prompt] = prompt if prompt.present?
        options
      end

      # Use configured scopes or the standard OIDC identity scopes.
      def openid_connect_scopes(cfg)
        custom_scopes = cfg.dig(:settings, :scopes).presence || cfg.dig(:settings, "scopes").presence
        return %i[openid email profile] if custom_scopes.blank?

        custom_scopes.to_s.split(/\s+/).map(&:to_sym)
      end

      # Honor the application certificate and TLS verification settings.
      def ssl_options
        ssl_config = Rails.configuration.x.ssl
        options = {}
        options[:ca_file] = ssl_config.ca_file if ssl_config&.ca_file.present?
        options[:verify] = false if ssl_config&.verify == false
        options
      end

      # Resolve the custom provider name with its identifier as fallback.
      def provider_name(cfg)
        (cfg[:name] || cfg[:id]).to_s
      end
  end
end
