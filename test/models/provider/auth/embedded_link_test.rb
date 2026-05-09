require "test_helper"

class Provider::Auth::EmbeddedLinkTest < ActiveSupport::TestCase
  setup do
    @connection = Provider::Connection.create!(
      family:       families(:empty),
      provider_key: "plaid",
      auth_type:    "embedded_link",
      credentials:  {},
      metadata:     { "region" => "us" },
      status:       :healthy
    )
    @auth = Provider::Auth::EmbeddedLink.new(@connection)
  end

  test "fresh_access_token returns persisted access_token" do
    @connection.update!(credentials: { "access_token" => "tok_123" })
    assert_equal "tok_123", @auth.fresh_access_token
  end

  test "store_access_token persists token without touching other credential keys" do
    @connection.update!(credentials: { "other_key" => "preserved" })
    @auth.store_access_token("tok_new")
    @connection.reload
    assert_equal "tok_new", @connection.credentials["access_token"]
    assert_equal "preserved", @connection.credentials["other_key"]
  end

  test "mark_requires_update! transitions status and records reason" do
    @connection.update!(status: :healthy)
    @auth.mark_requires_update!(reason: "ITEM_LOGIN_REQUIRED")
    @connection.reload
    assert @connection.requires_update?
    assert_equal "ITEM_LOGIN_REQUIRED", @connection.read_attribute(:sync_error)
  end

  test "mark_requires_update! defaults reason to reauth_required" do
    @auth.mark_requires_update!
    @connection.reload
    assert_equal "reauth_required", @connection.read_attribute(:sync_error)
  end
end
