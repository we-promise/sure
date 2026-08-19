# frozen_string_literal: true

require "test_helper"

class Api::V1::ProviderConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @mercury_item = mercury_items(:one)

    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      display_key: "test_read_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @read_write_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    redis = Redis.new
    redis.del("api_rate_limit:#{@api_key.id}")
    redis.del("api_rate_limit:#{@read_write_key.id}")
  end

  test "lists provider connection status for current family" do
    failed_sync = @mercury_item.syncs.create!(
      status: "failed",
      failed_at: Time.current,
      error: "secret token failed"
    )

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    mercury_connection = json_response["data"].detect do |connection|
      connection["id"] == @mercury_item.id && connection["provider"] == "mercury"
    end

    assert_not_nil mercury_connection
    assert_equal "mercury", mercury_connection["provider"]
    assert_equal "MercuryItem", mercury_connection["provider_type"]
    assert_equal @mercury_item.name, mercury_connection["name"]
    assert_equal @mercury_item.status, mercury_connection["status"]
    assert_includes [ true, false ], mercury_connection["requires_update"]
    assert_equal true, mercury_connection["credentials_configured"]
    assert_includes [ true, false ], mercury_connection["scheduled_for_deletion"]
    assert_includes [ true, false ], mercury_connection["pending_account_setup"]
    assert_equal @mercury_item.mercury_accounts.count, mercury_connection["accounts"]["total_count"]
    assert_equal failed_sync.id, mercury_connection["sync"]["latest"]["id"]
    assert_equal true, mercury_connection["sync"]["latest"]["error"]["present"]
    assert_equal "Sync failed", mercury_connection["sync"]["latest"]["error"]["message"]
  end

  test "reports failed sync errors as present without exposing raw messages" do
    failed_sync = @mercury_item.syncs.create!(
      status: "failed",
      failed_at: Time.current,
      error: nil
    )

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    mercury_connection = JSON.parse(response.body)["data"].detect do |connection|
      connection["id"] == @mercury_item.id && connection["provider"] == "mercury"
    end

    assert_equal failed_sync.id, mercury_connection["sync"]["latest"]["id"]
    assert_equal true, mercury_connection["sync"]["latest"]["error"]["present"]
    assert_equal "Sync failed", mercury_connection["sync"]["latest"]["error"]["message"]
  end

  test "reports stale sync errors as present" do
    stale_sync = @mercury_item.syncs.create!(
      status: "stale",
      syncing_at: 2.days.ago
    )

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    mercury_connection = JSON.parse(response.body)["data"].detect do |connection|
      connection["id"] == @mercury_item.id && connection["provider"] == "mercury"
    end

    assert_equal stale_sync.id, mercury_connection["sync"]["latest"]["id"]
    assert_equal true, mercury_connection["sync"]["latest"]["error"]["present"]
    assert_equal "Sync became stale before completion", mercury_connection["sync"]["latest"]["error"]["message"]
  end

  test "does not expose provider secrets or raw sync errors" do
    @mercury_item.syncs.create!(
      status: "failed",
      failed_at: Time.current,
      error: "raw provider token secret"
    )
    kraken_item = kraken_items(:one)
    kraken_item.syncs.create!(
      status: "failed",
      failed_at: Time.current,
      error: "raw kraken key secret"
    )

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    json_response = JSON.parse(response.body)
    kraken_connection = json_response["data"].detect do |connection|
      connection["id"] == kraken_item.id && connection["provider"] == "kraken"
    end

    assert_not_nil kraken_connection
    assert_equal "KrakenItem", kraken_connection["provider_type"]
    refute_includes response.body, @mercury_item.token
    refute_includes response.body, kraken_item.api_key
    refute_includes response.body, kraken_item.api_secret
    refute_includes response.body, "raw provider token secret"
    refute_includes response.body, "raw kraken key secret"
  end

  test "fails closed when credential readiness is unknown" do
    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    plaid_connection = JSON.parse(response.body)["data"].detect do |connection|
      connection["provider"] == "plaid"
    end

    assert_not_nil plaid_connection
    assert_includes [ true, false ], plaid_connection["requires_update"]
    assert_equal false, plaid_connection["credentials_configured"]
    assert_includes [ true, false ], plaid_connection["scheduled_for_deletion"]
    assert_includes [ true, false ], plaid_connection["pending_account_setup"]
  end

  test "excludes another family's provider connections" do
    other_item = snaptrade_items(:pending_registration_item)

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    ids = JSON.parse(response.body)["data"].map { |connection| connection["id"] }
    assert_not_includes ids, other_item.id
  end

  test "read_write key can list provider connection status" do
    get api_v1_provider_connections_url, headers: api_headers(@read_write_key)
    assert_response :success
  end

  test "lists Brex provider connection status" do
    brex_item = brex_items(:one)

    get api_v1_provider_connections_url, headers: api_headers(@api_key)
    assert_response :success

    brex_connection = JSON.parse(response.body)["data"].detect do |connection|
      connection["id"] == brex_item.id && connection["provider"] == "brex"
    end

    assert_not_nil brex_connection
    assert_equal "BrexItem", brex_connection["provider_type"]
    assert_equal brex_item.name, brex_connection["name"]
    assert_equal brex_item.brex_accounts.count, brex_connection["accounts"]["total_count"]
    assert_equal brex_item.linked_accounts_count, brex_connection["accounts"]["linked_count"]
    assert_equal brex_item.unlinked_accounts_count, brex_connection["accounts"]["unlinked_count"]
  end

  test "returns an empty list when no provider connections exist" do
    ProviderConnectionStatus.stub(:for_family, []) do
      get api_v1_provider_connections_url, headers: api_headers(@api_key)
    end

    assert_response :success
    assert_equal [], JSON.parse(response.body)["data"]
  end

  test "requires authentication" do
    get api_v1_provider_connections_url
    assert_response :unauthorized
  end

  test "rejects api keys without read scope" do
    write_only_key = ApiKey.new(
      user: @user,
      name: "Test Write Key",
      scopes: [ "write" ],
      display_key: "test_write_#{SecureRandom.hex(8)}",
      source: "monitoring"
    ).tap { |api_key| api_key.save!(validate: false) }

    get api_v1_provider_connections_url, headers: api_headers(write_only_key)
    assert_response :forbidden
  end

  test "does not leak internal provider status errors" do
    ProviderConnectionStatus.stub(:for_family, ->(_family) { raise StandardError, "secret provider failure" }) do
      get api_v1_provider_connections_url, headers: api_headers(@api_key)
    end

    assert_response :internal_server_error
    assert_equal "internal_server_error", JSON.parse(response.body)["error"]
    refute_includes response.body, "secret provider failure"
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end
end
