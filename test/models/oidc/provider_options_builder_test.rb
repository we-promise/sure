# frozen_string_literal: true

require "test_helper"

module Oidc
  class ProviderOptionsBuilderTest < ActiveSupport::TestCase
    test "uses default scopes when custom scopes are blank" do
      options = ProviderOptionsBuilder.call(base_config)

      assert_equal %i[openid email profile], options[:scope]
      assert_nil options[:extra_authorize_params]
    end

    test "requests groups claim when groups scope is configured" do
      options = ProviderOptionsBuilder.call(base_config(settings: { scopes: "openid email profile groups" }))

      claims = JSON.parse(options.dig(:extra_authorize_params, :claims))
      assert_equal [ "groups" ], claims["id_token"].keys
      assert_equal [ "groups" ], claims["userinfo"].keys
      assert_nil claims.dig("id_token", "groups")
      assert_nil claims.dig("userinfo", "groups")
    end

    test "requests groups claim when role mapping is configured" do
      options = ProviderOptionsBuilder.call(base_config(settings: {
        role_mapping: { super_admin: [ "sure-admins" ] }
      }))

      claims = JSON.parse(options.dig(:extra_authorize_params, :claims))
      assert_equal [ "groups" ], claims["id_token"].keys
      assert_equal [ "groups" ], claims["userinfo"].keys
    end

    test "does not request groups claim for regular OIDC login without group mapping" do
      options = ProviderOptionsBuilder.call(base_config(settings: { scopes: "openid email profile" }))

      assert_nil options[:extra_authorize_params]
    end

    test "discards blank scope tokens from surrounding whitespace" do
      options = ProviderOptionsBuilder.call(base_config(settings: { scopes: "  openid   email profile groups  " }))

      assert_equal %i[openid email profile groups], options[:scope]
    end

    test "returns nil when required configuration is missing" do
      config = base_config.except(:client_secret)

      assert_nil ProviderOptionsBuilder.call(
        config,
        env: {},
        rails_env: ActiveSupport::StringInquirer.new("production")
      )
    end

    test "includes configured prompt" do
      options = ProviderOptionsBuilder.call(base_config(settings: { prompt: "login" }))

      assert_equal "login", options[:prompt]
    end

    private
      def base_config(overrides = {})
        {
          name: "openid_connect",
          strategy: "openid_connect",
          issuer: "https://idp.example.com",
          client_id: "client-id",
          client_secret: "client-secret",
          redirect_uri: "https://sure.example.com/auth/openid_connect/callback",
          settings: {}
        }.deep_merge(overrides)
      end
  end
end
