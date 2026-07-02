# frozen_string_literal: true

class OmniauthProviderRegistry
  Registration = Struct.new(:strategy, :args, :options, :config, keyword_init: true)

  class << self
    def register(builder, raw_cfg)
      registration = registration_for(raw_cfg)
      return unless registration

      builder.provider registration.strategy, *registration.args, registration.options
      registration.config
    end

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

    def register_dynamic_database_oidc_provider(builder)
      builder.provider :openid_connect, dynamic_database_oidc_options
    end

    private
      def openid_connect_registration(cfg)
        name = provider_name(cfg)
        issuer = cfg[:issuer].presence || ENV["OIDC_ISSUER"].presence
        client_id = cfg[:client_id].presence || ENV["OIDC_CLIENT_ID"].presence
        client_secret = cfg[:client_secret].presence || ENV["OIDC_CLIENT_SECRET"].presence
        redirect_uri = cfg[:redirect_uri].presence || ENV["OIDC_REDIRECT_URI"].presence

        if Rails.env.test?
          issuer ||= "https://test.example.com"
          client_id ||= "test_client_id"
          client_secret ||= "test_client_secret"
          redirect_uri ||= "http://test.example.com/callback"
        end

        unless issuer.present? && client_id.present? && client_secret.present? && redirect_uri.present?
          Rails.logger.warn("[OmniAuth] Skipping OIDC provider '#{name}' - missing required configuration")
          return
        end

        Registration.new(
          strategy: :openid_connect,
          args: [],
          options: openid_connect_options(cfg, name, issuer, client_id, client_secret, redirect_uri),
          config: cfg.merge(name: name, issuer: issuer)
        )
      end

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

      def dynamic_database_oidc_options
        {
          name: :db_openid_connect,
          request_path: method(:database_oidc_request_path?),
          callback_path: method(:database_oidc_callback_path?),
          setup: method(:setup_database_oidc_provider)
        }.merge(openid_connect_options({}, "db_openid_connect", nil, nil, nil, nil))
      end

      def database_oidc_request_path?(env)
        database_oidc_config_for(env).present? && !callback_request?(env)
      end

      def database_oidc_callback_path?(env)
        database_oidc_config_for(env).present? && callback_request?(env)
      end

      def setup_database_oidc_provider(env)
        registration = database_oidc_registration_for(env)
        return unless registration

        strategy = env["omniauth.strategy"]
        strategy.options.deep_merge!(registration.options)
      end

      def database_oidc_config_for(env)
        database_oidc_registration_for(env)&.config
      end

      def database_oidc_registration_for(env)
        return unless FeatureFlags.db_sso_providers?
        return env["sure.omniauth.database_oidc_registration"] if env.key?("sure.omniauth.database_oidc_registration")

        name = auth_path_provider_name(env)
        return env["sure.omniauth.database_oidc_registration"] = nil if name.blank? || name == "failure" || name == "logout"

        ProviderLoader.load_providers.each do |provider|
          next unless provider[:strategy].to_s == "openid_connect" && provider[:name].to_s == name

          return env["sure.omniauth.database_oidc_registration"] = openid_connect_registration(provider)
        end

        env["sure.omniauth.database_oidc_registration"] = nil
      end

      def auth_path_provider_name(env)
        path = env["PATH_INFO"].to_s
        match = path.match(%r{\A/auth/([^/]+)(?:/callback)?\z})
        match&.[](1)
      end

      def callback_request?(env)
        env["PATH_INFO"].to_s.end_with?("/callback")
      end

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

      def openid_connect_scopes(cfg)
        custom_scopes = cfg.dig(:settings, :scopes).presence || cfg.dig(:settings, "scopes").presence
        return %i[openid email profile] if custom_scopes.blank?

        custom_scopes.to_s.split(/\s+/).map(&:to_sym)
      end

      def ssl_options
        ssl_config = Rails.configuration.x.ssl
        options = {}
        options[:ca_file] = ssl_config.ca_file if ssl_config&.ca_file.present?
        options[:verify] = false if ssl_config&.verify == false
        options
      end

      def provider_name(cfg)
        (cfg[:name] || cfg[:id]).to_s
      end
  end
end
