require "test_helper"
require Rails.root.join("test/support/scalable_test_helper")

class ScalableItemTest < ActiveSupport::TestCase
  include ScalableTestHelper

  setup do
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)
    Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
  end

  test "stores credentials encrypted and requires explicit encryption and an authorized owner" do
    item = scalable_connected_item
    stored = ScalableItem.connection.select_one("SELECT credentials, person_identity FROM scalable_items WHERE id = #{ScalableItem.connection.quote(item.id)}")
    refute_includes stored.fetch("credentials"), "synthetic-refresh"
    refute_equal item.person_identity, stored.fetch("person_identity")
    assert item.ready_for_sync?
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(false)
    refute item.ready_for_sync?
    refute item.valid?
    assert_equal :tenant_wide, ScalableItem.declared_credential_scope
  end

  test "refresh rotation survives a later rejected snapshot while financial changes roll back" do
    item = scalable_connected_item
    rotated = scalable_credentials(refresh: "replacement-refresh")
    callback = nil
    provider = mock("provider")
    Provider::Scalable.expects(:new).with do |credentials:, on_credentials_update:|
      callback = on_credentials_update
      credentials.fetch("refresh_token") == "synthetic-refresh"
    end.returns(provider)
    provider.expects(:refresh_if_needed!)

    error = assert_raises(Provider::Scalable::Error) do
      item.with_authenticated_provider do
        callback.call(rotated)
        item.update!(snapshot_at: Time.current)
        raise Provider::Scalable::Error.new(:incomplete_snapshot)
      end
    end
    assert_equal "incomplete_snapshot", error.code
    assert_equal "replacement-refresh", item.reload.credentials_data.fetch("refresh_token")
    assert_nil item.snapshot_at
    assert item.connected?
    assert_equal "incomplete_snapshot", item.last_sync_error_code
  end

  test "rejects changed person or DPoP key without replacing credentials" do
    item = scalable_connected_item
    callback = nil
    provider = mock("provider")
    Provider::Scalable.stubs(:new).with do |on_credentials_update:, **|
      callback = on_credentials_update
      true
    end.returns(provider)
    provider.expects(:refresh_if_needed!)

    error = assert_raises(Provider::Scalable::Error) do
      item.with_authenticated_provider { callback.call(scalable_credentials(person: "other-person")) }
    end
    assert_equal "account_identity_changed", error.code
    assert_equal "synthetic-person", item.reload.person_identity
    assert_equal "synthetic-refresh", item.credentials_data.fetch("refresh_token")
    assert item.requires_update?
  end

  test "disconnect retains saved account identity and snapshot while revoking credentials" do
    item = scalable_connected_item
    item.update!(snapshot_at: 1.day.ago)
    item.disconnect!
    assert_nil item.reload.credentials
    assert_equal "synthetic-person", item.person_identity
    assert item.snapshot_at
    assert_equal 2, item.connection_generation
    refute item.session_configured?
  end

  test "retryable rate limiting preserves the session and schedules a cooldown" do
    item = scalable_connected_item
    provider = mock("provider")
    Provider::Scalable.stubs(:new).returns(provider)
    provider.expects(:refresh_if_needed!).raises(Provider::Scalable::Error.new(:rate_limited))
    assert_raises(Provider::Scalable::Error) { item.with_authenticated_provider { flunk } }
    assert item.reload.connected?
    assert item.next_sync_at > Time.current
    refute ScalableItem.syncable.exists?(item.id)
  end
end
