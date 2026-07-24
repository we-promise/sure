# frozen_string_literal: true

module Oidc
  class ProviderOptionsBuilder
    DEFAULT_SCOPES = %i[openid email profile].freeze

    class << self
      def call(raw_cfg, env: ENV, rails_env: Rails.env, ssl_config: Rails.configuration.x.ssl)
        cfg = raw_cfg.deep_symbolize_keys
        name = (cfg[:name] || cfg[:id]).to_s

        issuer = cfg[:issuer].presence || env["OIDC_ISSUER"].presence
        client_id = cfg[:client_id].presence || env["OIDC_CLIENT_ID"].presence
        client_secret = cfg[:client_secret].presence || env["OIDC_CLIENT_SECRET"].presence
        redirect_uri = cfg[:redirect_uri].presence || env["OIDC_REDIRECT_URI"].presence

        if rails_env.test?
          issuer ||= "https://test.example.com"
          client_id ||= "test_client_id"
          client_secret ||= "test_client_secret"
          redirect_uri ||= "http://test.example.com/callback"
        end

        return nil unless issuer.present? && client_id.present? && client_secret.present? && redirect_uri.present?

        scopes = oidc_scopes(cfg)

        options = {
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
            ssl: ssl_options(ssl_config)
          }
        }

        prompt = cfg.dig(:settings, :prompt).presence
        options[:prompt] = prompt if prompt.present?

        extra_authorize_params = oidc_extra_authorize_params(cfg, scopes)
        options[:extra_authorize_params] = extra_authorize_params if extra_authorize_params.present?

        options
      end

      def oidc_scopes(cfg)
        custom_scopes = cfg.dig(:settings, :scopes).presence
        return DEFAULT_SCOPES unless custom_scopes.present?

        custom_scopes.to_s.split.map(&:to_sym)
      end

      def oidc_extra_authorize_params(cfg, scopes = oidc_scopes(cfg))
        return {} unless request_groups_claim?(cfg, scopes)

        {
          claims: JSON.generate(
            id_token: { groups: nil },
            userinfo: { groups: nil }
          )
        }
      end

      def request_groups_claim?(cfg, scopes = oidc_scopes(cfg))
        scopes.map(&:to_s).include?("groups") || role_mapping(cfg).present?
      end

      private
        def role_mapping(cfg)
          cfg.dig(:settings, :role_mapping).presence
        end

        def ssl_options(ssl_config)
          ssl_opts = {}
          ssl_opts[:ca_file] = ssl_config.ca_file if ssl_config&.ca_file.present?
          ssl_opts[:verify] = false if ssl_config&.verify == false
          ssl_opts
        end
    end
  end
end
