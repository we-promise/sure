require "test_helper"

class OmniauthProviderRegistryTest < ActiveSupport::TestCase
  setup do
    @previous_test_mode = OmniAuth.config.test_mode
    @previous_mock_auth = OmniAuth.config.mock_auth.dup
    @previous_sso_providers = Rails.configuration.x.auth.sso_providers
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.test_mode = @previous_test_mode
    OmniAuth.config.mock_auth = @previous_mock_auth
    Rails.configuration.x.auth.sso_providers = @previous_sso_providers
  end

  test "registers custom database OIDC provider callbacks dynamically" do
    FeatureFlags.stubs(:db_sso_providers?).returns(true)
    ProviderLoader.stubs(:load_providers).returns([ custom_oidc_provider ])

    OmniAuth.config.mock_auth[:authentik] = OmniAuth::AuthHash.new(
      provider: "authentik",
      uid: "uid-123",
      info: { email: "person@example.com" }
    )

    response = Rack::MockRequest.new(dynamic_omniauth_app).get("/auth/authentik/callback")

    assert_equal 200, response.status
    assert_equal "authentik", response.body
  end

  test "dynamic OIDC setup uses the custom provider name and redirect URI" do
    registration = OmniauthProviderRegistry.registration_for(custom_oidc_provider)

    assert_equal :openid_connect, registration.strategy
    assert_equal :authentik, registration.options[:name]
    assert_equal "https://app.example.com/auth/authentik/callback", registration.options.dig(:client_options, :redirect_uri)
    assert_equal "login", registration.options[:prompt]
    assert_equal "authentik", registration.config[:name]
  end

  test "does not intercept incomplete database OIDC providers" do
    Rails.env.stubs(:test?).returns(false)
    FeatureFlags.stubs(:db_sso_providers?).returns(true)
    ProviderLoader.stubs(:load_providers).returns([
      custom_oidc_provider.except(:client_secret)
    ])

    response = Rack::MockRequest.new(dynamic_omniauth_app).get("/auth/authentik/callback")

    assert_equal 200, response.status
    assert_equal "no auth", response.body
  end

  test "auth config returns current database providers instead of stale boot providers" do
    FeatureFlags.stubs(:db_sso_providers?).returns(true)
    Rails.configuration.x.auth.sso_providers = [
      { id: "oidc", strategy: "openid_connect", name: "openid_connect" }
    ]
    ProviderLoader.stubs(:load_providers).returns([ custom_oidc_provider ])

    providers = AuthConfig.sso_providers

    assert_equal [ "authentik" ], providers.map { |provider| provider[:name] }
  end

  private
    def dynamic_omniauth_app
      Rack::Builder.new do
        use Rack::Session::Cookie, secret: "a" * 64

        use OmniAuth::Builder do
          OmniauthProviderRegistry.register_dynamic_database_oidc_provider(self)
        end

        run lambda { |env|
          auth = env["omniauth.auth"]
          [ 200, { "content-type" => "text/plain" }, [ auth&.provider || "no auth" ] ]
        }
      end.to_app
    end

    def custom_oidc_provider
      {
        id: "authentik",
        strategy: "openid_connect",
        name: "authentik",
        label: "Sign in with Authentik",
        issuer: "https://idp.example.com",
        client_id: "client-id",
        client_secret: "client-secret",
        redirect_uri: "https://app.example.com/auth/authentik/callback",
        settings: {
          scopes: "openid email profile groups",
          prompt: "login"
        }
      }
    end
end
