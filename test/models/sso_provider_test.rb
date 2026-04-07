require "test_helper"

class SsoProviderTest < ActiveSupport::TestCase
  test "valid provider with all required fields" do
    provider = SsoProvider.new(
      strategy: "openid_connect",
      name: "test_oidc",
      label: "Test OIDC",
      enabled: true,
      issuer: "https://test.example.com",
      client_id: "test_client",
      client_secret: "test_secret"
    )
    assert provider.valid?
  end

  test "requires strategy" do
    provider = SsoProvider.new(name: "test", label: "Test")
    assert_not provider.valid?
    assert_includes provider.errors[:strategy], "can't be blank"
  end

  test "requires name" do
    provider = SsoProvider.new(strategy: "openid_connect", label: "Test")
    assert_not provider.valid?
    assert_includes provider.errors[:name], "can't be blank"
  end

  test "requires label" do
    provider = SsoProvider.new(strategy: "openid_connect", name: "test")
    assert_not provider.valid?
    assert_includes provider.errors[:label], "can't be blank"
  end

  test "requires unique name" do
    SsoProvider.create!(
      strategy: "openid_connect",
      name: "duplicate",
      label: "First",
      client_id: "id1",
      client_secret: "secret1",
      issuer: "https://first.example.com"
    )

    provider = SsoProvider.new(
      strategy: "google_oauth2",
      name: "duplicate",
      label: "Second",
      client_id: "id2",
      client_secret: "secret2"
    )

    assert_not provider.valid?
    assert_includes provider.errors[:name], "has already been taken"
  end

  test "validates name format" do
    provider = SsoProvider.new(
      strategy: "openid_connect",
      name: "Invalid-Name!",
      label: "Test",
      client_id: "test",
      client_secret: "secret",
      issuer: "https://test.example.com"
    )

    assert_not provider.valid?
    assert_includes provider.errors[:name], "must contain only lowercase letters, numbers, and underscores"
  end

  test "validates strategy inclusion" do
    provider = SsoProvider.new(
      strategy: "invalid_strategy",
      name: "test",
      label: "Test"
    )

    assert_not provider.valid?
    assert_includes provider.errors[:strategy], "invalid_strategy is not a supported strategy"
  end

  test "encrypts client_secret" do
    skip "Encryption not configured" unless SsoProvider.encryption_ready?

    provider = SsoProvider.create!(
      strategy: "openid_connect",
      name: "encrypted_test",
      label: "Encrypted Test",
      client_id: "test_client",
      client_secret: "super_secret_value",
      issuer: "https://test.example.com"
    )

    # Reload from database
    provider.reload

    # Should be able to read decrypted value
    assert_equal "super_secret_value", provider.client_secret

    # Raw database value should be encrypted (not plain text)
    raw_value = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array(
        [ "SELECT client_secret FROM sso_providers WHERE id = ?", provider.id ]
      )
    )

    assert_not_equal "super_secret_value", raw_value
  end

  test "OIDC provider requires issuer" do
    provider = SsoProvider.new(
      strategy: "openid_connect",
      name: "test_oidc",
      label: "Test",
      client_id: "test",
      client_secret: "secret"
    )

    assert_not provider.valid?
    assert_includes provider.errors[:issuer], "is required for OpenID Connect providers"
  end

  test "OIDC provider requires client_id" do
    provider = SsoProvider.new(
      strategy: "openid_connect",
      name: "test_oidc",
      label: "Test",
      issuer: "https://test.example.com",
      client_secret: "secret"
    )

    assert_not provider.valid?
    assert_includes provider.errors[:client_id], "is required for OpenID Connect providers"
  end

  test "OIDC provider requires client_secret" do
    provider = SsoProvider.new(
      strategy: "openid_connect",
      name: "test_oidc",
      label: "Test",
      issuer: "https://test.example.com",
      client_id: "test"
    )

    assert_not provider.valid?
    assert_includes provider.errors[:client_secret], "is required for OpenID Connect providers"
  end

  test "OIDC provider validates issuer URL format" do
    provider = SsoProvider.new(
      strategy: "openid_connect",
      name: "test_oidc",
      label: "Test",
      issuer: "not-a-valid-url",
      client_id: "test",
      client_secret: "secret"
    )

    assert_not provider.valid?
    assert_includes provider.errors[:issuer], "must be a valid URL"
  end

  test "OAuth provider requires client_id" do
    provider = SsoProvider.new(
      strategy: "google_oauth2",
      name: "test_google",
      label: "Test",
      client_secret: "secret"
    )

    assert_not provider.valid?
    assert_includes provider.errors[:client_id], "is required for OAuth providers"
  end

  test "OAuth provider requires client_secret" do
    provider = SsoProvider.new(
      strategy: "google_oauth2",
      name: "test_google",
      label: "Test",
      client_id: "test"
    )

    assert_not provider.valid?
    assert_includes provider.errors[:client_secret], "is required for OAuth providers"
  end

  test "enabled scope returns only enabled providers" do
    enabled = SsoProvider.create!(
      strategy: "openid_connect",
      name: "enabled_provider",
      label: "Enabled",
      enabled: true,
      client_id: "test",
      client_secret: "secret",
      issuer: "https://enabled.example.com"
    )

    SsoProvider.create!(
      strategy: "openid_connect",
      name: "disabled_provider",
      label: "Disabled",
      enabled: false,
      client_id: "test",
      client_secret: "secret",
      issuer: "https://disabled.example.com"
    )

    assert_includes SsoProvider.enabled, enabled
    assert_equal 1, SsoProvider.enabled.count
  end

  test "by_strategy scope filters by strategy" do
    oidc = SsoProvider.create!(
      strategy: "openid_connect",
      name: "oidc_provider",
      label: "OIDC",
      client_id: "test",
      client_secret: "secret",
      issuer: "https://oidc.example.com"
    )

    SsoProvider.create!(
      strategy: "google_oauth2",
      name: "google_provider",
      label: "Google",
      client_id: "test",
      client_secret: "secret"
    )

    oidc_providers = SsoProvider.by_strategy("openid_connect")
    assert_includes oidc_providers, oidc
    assert_equal 1, oidc_providers.count
  end



  test "normalizes icon by stripping whitespace before validation" do
    provider = SsoProvider.new(
      strategy: "openid_connect",
      name: "icon_normalized",
      label: "Icon Normalized",
      icon: "  key  ",
      issuer: "https://test.example.com",
      client_id: "test_client",
      client_secret: "test_secret"
    )

    assert provider.valid?
    assert_equal "key", provider.icon
  end

  test "normalizes whitespace-only icon to nil" do
    provider = SsoProvider.new(
      strategy: "openid_connect",
      name: "icon_nil",
      label: "Icon Nil",
      icon: "   ",
      issuer: "https://test.example.com",
      client_id: "test_client",
      client_secret: "test_secret"
    )

    assert provider.valid?
    assert_nil provider.icon
  end

  test "to_omniauth_config returns correct hash" do
    provider = SsoProvider.create!(
      strategy: "openid_connect",
      name: "test_oidc",
      label: "Test OIDC",
      icon: "key",
      enabled: true,
      issuer: "https://test.example.com",
      client_id: "test_client",
      client_secret: "test_secret",
      redirect_uri: "https://app.example.com/callback",
      settings: { scope: "openid email" }
    )

    config = provider.to_omniauth_config

    assert_equal "test_oidc", config[:id]
    assert_equal "openid_connect", config[:strategy]
    assert_equal "test_oidc", config[:name]
    assert_equal "Test OIDC", config[:label]
    assert_equal "key", config[:icon]
    assert_equal "https://test.example.com", config[:issuer]
    assert_equal "test_client", config[:client_id]
    assert_equal "test_secret", config[:client_secret]
    assert_equal "https://app.example.com/callback", config[:redirect_uri]
    assert_equal({ "scope" => "openid email" }, config[:settings])
  end

  # Note: OIDC discovery validation tests are skipped in test environment
  # Discovery validation is disabled in test mode to avoid VCR cassette requirements
  # In production, the validate_oidc_discovery method will validate the issuer's
  # .well-known/openid-configuration endpoint
end
