require "test_helper"

class AuthConfigTest < ActiveSupport::TestCase
  # Issue #1617: AuthConfig.sso_providers and ProviderLoader.load_providers had
  # overlapping resolution paths and inconsistent key normalization. YAML-sourced
  # providers came back string-keyed while DB-sourced providers (via
  # SsoProvider#to_omniauth_config) came back symbol-keyed, forcing every
  # consumer to defensively re-symbolize.
  #
  # AuthConfig is now the single canonical source of truth and guarantees
  # symbol keys at the boundary regardless of underlying provider source.

  setup do
    @original_providers = Rails.configuration.x.auth.sso_providers
  end

  teardown do
    Rails.configuration.x.auth.sso_providers = @original_providers
  end

  test "sso_providers normalizes string-keyed YAML provider hashes to symbol keys" do
    Rails.configuration.x.auth.sso_providers = [
      { "name" => "yaml_oidc", "id" => "yaml_oidc", "strategy" => "openid_connect", "label" => "Test" }
    ]

    providers = AuthConfig.sso_providers

    assert_equal 1, providers.length
    assert_equal "yaml_oidc", providers.first[:name]
    assert_equal "openid_connect", providers.first[:strategy]
    assert_nil providers.first["name"], "must not leak string keys after normalization"
  end

  test "sso_providers leaves already symbol-keyed DB provider hashes intact" do
    Rails.configuration.x.auth.sso_providers = [
      { name: "db_oidc", id: "db_oidc", strategy: "openid_connect", label: "DB Test" }
    ]

    providers = AuthConfig.sso_providers

    assert_equal "db_oidc", providers.first[:name]
    assert_equal "openid_connect", providers.first[:strategy]
  end

  test "sso_providers normalizes mixed string-and-symbol-keyed hashes (omniauth.rb's cfg.merge shape)" do
    # omniauth.rb pushes `cfg.merge(name: name, issuer: issuer)` — cfg from YAML
    # is string-keyed, the merged entries are symbol-keyed. Consumers must see
    # all-symbol keys after AuthConfig normalization.
    Rails.configuration.x.auth.sso_providers = [
      { "client_id" => "abc", "client_secret" => "xyz", "strategy" => "openid_connect", name: "mixed", issuer: "https://idp.example/" }
    ]

    providers = AuthConfig.sso_providers

    assert_equal "abc", providers.first[:client_id]
    assert_equal "mixed", providers.first[:name]
    assert_equal "https://idp.example/", providers.first[:issuer]
    assert_nil providers.first["client_id"], "string-keyed entries must be symbolized"
  end

  test "sso_providers returns [] when nothing is configured" do
    Rails.configuration.x.auth.sso_providers = nil
    assert_equal [], AuthConfig.sso_providers
  end

  test "find_sso_provider returns the provider config matching name" do
    Rails.configuration.x.auth.sso_providers = [
      { name: "authentik", id: "authentik", strategy: "openid_connect", label: "Authentik" }
    ]

    cfg = AuthConfig.find_sso_provider("authentik")

    assert_not_nil cfg
    assert_equal "authentik", cfg[:name]
    assert_equal "openid_connect", cfg[:strategy]
  end

  test "find_sso_provider matches by id when name does not match" do
    Rails.configuration.x.auth.sso_providers = [
      { name: "okta_sso", id: "okta", strategy: "openid_connect" }
    ]

    cfg = AuthConfig.find_sso_provider("okta")
    assert_not_nil cfg
    assert_equal "okta_sso", cfg[:name]
  end

  test "find_sso_provider returns nil for blank input" do
    Rails.configuration.x.auth.sso_providers = [ { name: "a", id: "a", strategy: "openid_connect" } ]
    assert_nil AuthConfig.find_sso_provider(nil)
    assert_nil AuthConfig.find_sso_provider("")
  end

  test "find_sso_provider returns nil for unknown provider" do
    Rails.configuration.x.auth.sso_providers = [ { name: "known", id: "known", strategy: "openid_connect" } ]
    assert_nil AuthConfig.find_sso_provider("unknown")
  end

  # PR #1905 review (Codex P1): name match must win over an id match anywhere in
  # the list, even when another provider's id aliases this lookup key — a
  # single-pass OR could otherwise resolve a name lookup to the wrong provider.
  test "find_sso_provider prefers a name match over an id match earlier in the list" do
    Rails.configuration.x.auth.sso_providers = [
      { name: "shadow", id: "authentik", strategy: "openid_connect", label: "Decoy (id alias)" },
      { name: "authentik", id: "authentik_real", strategy: "openid_connect", label: "Real Authentik" }
    ]

    cfg = AuthConfig.find_sso_provider("authentik")

    assert_equal "authentik", cfg[:name]
    assert_equal "Real Authentik", cfg[:label],
      "a name match must win over an id match that appears earlier in the list"
  end

  test "find_sso_provider returns symbol-keyed config even when underlying source is string-keyed" do
    Rails.configuration.x.auth.sso_providers = [
      { "name" => "yaml_only", "id" => "yaml_only", "strategy" => "openid_connect", "label" => "YAML" }
    ]

    cfg = AuthConfig.find_sso_provider("yaml_only")

    assert_not_nil cfg
    assert_equal "yaml_only", cfg[:name]
    assert_equal "YAML", cfg[:label]
  end

  test "clear_sso_provider_cache delegates to the underlying provider loader" do
    ProviderLoader.expects(:clear_cache).once
    AuthConfig.clear_sso_provider_cache
  end

  # PR #1905 review (maintainer): cover the DB branch that falls back to
  # ProviderLoader. The other tests stub Rails.configuration directly; this one
  # exercises the FeatureFlags → ProviderLoader path and proves normalization
  # still applies to whatever the loader returns (string-keyed here).
  test "sso_providers normalizes the ProviderLoader fallback when db providers are enabled" do
    FeatureFlags.stubs(:db_sso_providers?).returns(true)
    Rails.configuration.x.auth.sso_providers = []
    ProviderLoader.stubs(:load_providers).returns([
      { "name" => "db_loaded", "id" => "db_loaded", "strategy" => "openid_connect", "label" => "DB Loaded" }
    ])

    providers = AuthConfig.sso_providers

    assert_equal 1, providers.length
    assert_equal "db_loaded", providers.first[:name]
    assert_nil providers.first["name"], "ProviderLoader output must be symbolized like every other source"
  end
end
