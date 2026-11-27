require "test_helper"

class RefreshSaxoSessionsJobTest < ActiveJob::TestCase
  setup do
    Setting.saxo_app_key = "test-key"
    Setting.saxo_app_secret = "test-secret"
    @item = families(:dylan_family).saxo_items.create!(access_token: "old", refresh_token: "old-refresh",
      access_expires_at: 1.minute.from_now, refresh_expires_at: 30.minutes.from_now,
      application_key_digest: Provider::Saxo.application_key_digest)
  end

  teardown do
    Setting.saxo_app_key = nil
    Setting.saxo_app_secret = nil
  end

  test "session maintenance rotates tokens without scheduling financial imports" do
    Provider::Saxo.expects(:exchange).returns(access_token: "new", refresh_token: "new-refresh",
      access_expires_at: 20.minutes.from_now, refresh_expires_at: 40.minutes.from_now)
    SaxoItem.any_instance.expects(:sync_later).never
    RefreshSaxoSessionsJob.perform_now
    assert_equal "new-refresh", @item.reload.refresh_token
  end

  test "a temporary outage is logged as a warning with its diagnostic" do
    Provider::Saxo.expects(:exchange).raises(Provider::Saxo::Error.new("Saxo authorization service is temporarily unavailable",
      diagnostic: { stage: "token_exchange", reason: "network_error" }))

    assert_difference -> { DebugLogEntry.count }, 1 do
      RefreshSaxoSessionsJob.perform_now
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal [ "provider_sync_error", "warn" ], [ entry.category, entry.level ]
    assert_equal({ "stage" => "token_exchange", "reason" => "network_error", "saxo_item_id" => @item.id }, entry.metadata)
    assert @item.reload.good?
  end

  test "a rejected authorization is logged as an authorization error" do
    Provider::Saxo.expects(:exchange).raises(Provider::Saxo::AuthenticationError.new("Saxo authorization service rejected the request",
      diagnostic: { stage: "token_exchange", reason: "http_error", http_status: 400 }))

    RefreshSaxoSessionsJob.perform_now

    entry = DebugLogEntry.order(:created_at).last
    assert_equal [ "provider_auth_error", "error" ], [ entry.category, entry.level ]
    assert_equal 400, entry.metadata["http_status"]
    assert @item.reload.requires_update?
  end
end
