require "test_helper"

class Provider::ConnectionTest < ActiveSupport::TestCase
  test "belongs to family and provider_family_config" do
    conn = provider_connections(:monzo_connection)
    assert_equal families(:dylan_family), conn.family
    assert_equal provider_family_configs(:truelayer_family_one), conn.provider_family_config
  end

  test "has many provider_accounts" do
    conn = provider_connections(:monzo_connection)
    assert_includes conn.provider_accounts, provider_accounts(:monzo_current)
  end

  test "pending_setup? when unlinked accounts exist" do
    conn = provider_connections(:monzo_connection)
    assert conn.pending_setup?
  end

  test "not pending_setup? when all accounts linked" do
    provider_accounts(:monzo_unlinked).update!(account: accounts(:depository))
    conn = provider_connections(:monzo_connection)
    assert_not conn.pending_setup?
  end

  test "healthy? returns true when status is healthy" do
    conn = provider_connections(:monzo_connection)
    assert conn.healthy?
  end

  test "requires provider_key" do
    conn = Provider::Connection.new(family: families(:dylan_family), auth_type: "oauth2")
    assert_not conn.valid?
    assert conn.errors[:provider_key].any?
  end

  test "requires auth_type" do
    conn = Provider::Connection.new(family: families(:dylan_family), provider_key: "truelayer")
    assert_not conn.valid?
    assert conn.errors[:auth_type].any?
  end

  test "syncer returns correct syncer instance for registered provider" do
    family = families(:empty)
    conn = Provider::Connection.create!(
      family: family, provider_key: "truelayer", auth_type: "oauth2",
      credentials: {}, status: :healthy
    )
    assert_instance_of Provider::Truelayer::Syncer, conn.send(:syncer)
  end

  test "syncer raises NotImplementedError for unknown provider" do
    family = families(:empty)
    conn = Provider::Connection.new(
      family: family, provider_key: "unknown_provider", auth_type: "oauth2",
      credentials: {}, status: :healthy
    )
    assert_raises(NotImplementedError) { conn.send(:syncer) }
  end

  test "syncer raises NotImplementedError for adapter without syncer_class" do
    stub_adapter = Class.new
    Provider::ConnectionRegistry.register("stub_no_syncer", stub_adapter)
    conn = Provider::Connection.new(
      family: families(:empty), provider_key: "stub_no_syncer",
      auth_type: "oauth2", credentials: {}, status: :healthy
    )
    error = assert_raises(NotImplementedError) { conn.send(:syncer) }
    assert_match "does not define syncer_class", error.message
  ensure
    Provider::ConnectionRegistry.send(:registry).delete("stub_no_syncer")
  end

  test "auth returns instance of adapter's declared auth_class" do
    conn = provider_connections(:monzo_connection)
    assert_instance_of Provider::Auth::OAuth2, conn.auth
  end

  test "auth raises NotImplementedError for adapter without auth_class" do
    stub_adapter = Class.new { extend Provider::ConnectionAdapter }
    Provider::ConnectionRegistry.register("stub_no_auth", stub_adapter)
    conn = Provider::Connection.new(
      family: families(:empty), provider_key: "stub_no_auth",
      auth_type: "oauth2", credentials: {}, status: :healthy
    )
    error = assert_raises(NotImplementedError) { conn.auth }
    assert_match "auth_class", error.message
  ensure
    Provider::ConnectionRegistry.send(:registry).delete("stub_no_auth")
  end

  test "institution_name returns provider display_name from raw_payload" do
    conn = provider_connections(:monzo_connection)
    assert_equal "Monzo", conn.institution_name
  end

  test "institution_name falls back to titleized provider_key" do
    conn = provider_connections(:monzo_connection)
    provider_accounts(:monzo_current).update!(raw_payload: {})
    provider_accounts(:monzo_unlinked).update!(raw_payload: {})
    assert_equal "Truelayer", conn.institution_name
  end

  test "logo_uri returns https url from provider raw_payload" do
    conn = provider_connections(:monzo_connection)
    assert_equal "https://truelayer-client-logos.s3-eu-west-1.amazonaws.com/banks/banks-icons/ob-monzo-icon.svg",
                 conn.logo_uri
  end

  test "logo_uri returns nil when provider raw_payload has no logo_uri" do
    provider_accounts(:monzo_current).update!(raw_payload: { "provider" => { "display_name" => "Monzo" } })
    conn = provider_connections(:monzo_connection)
    assert_nil conn.logo_uri
  end

  test "logo_uri returns nil when raw_payload is empty" do
    provider_accounts(:monzo_current).update!(raw_payload: {})
    conn = provider_connections(:monzo_connection)
    assert_nil conn.logo_uri
  end

  test "logo_uri returns nil for non-http uri" do
    provider_accounts(:monzo_current).update!(raw_payload: { "provider" => { "logo_uri" => "javascript:alert(1)" } })
    conn = provider_connections(:monzo_connection)
    assert_nil conn.logo_uri
  end

  test "syncable scope includes healthy and requires_update; excludes disconnected" do
    family = families(:empty)
    healthy       = Provider::Connection.create!(family: family, provider_key: "truelayer", auth_type: "oauth2", credentials: {}, status: :healthy)
    req_update    = Provider::Connection.create!(family: family, provider_key: "truelayer", auth_type: "oauth2", credentials: {}, status: :requires_update)
    disconnected  = Provider::Connection.create!(family: family, provider_key: "truelayer", auth_type: "oauth2", credentials: {}, status: :disconnected)

    ids = Provider::Connection.syncable.pluck(:id)
    assert_includes ids, healthy.id
    assert_includes ids, req_update.id
    assert_not_includes ids, disconnected.id
  end
end
