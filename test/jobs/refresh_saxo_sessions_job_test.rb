require "test_helper"

class RefreshSaxoSessionsJobTest < ActiveJob::TestCase
  test "session maintenance rotates tokens without scheduling financial imports" do
    Setting.saxo_app_key = "test-key"
    Setting.saxo_app_secret = "test-secret"
    item = families(:dylan_family).saxo_items.create!(access_token: "old", refresh_token: "old-refresh",
      access_expires_at: 1.minute.from_now, refresh_expires_at: 30.minutes.from_now,
      application_key_digest: Provider::Saxo.application_key_digest)
    Provider::Saxo.expects(:exchange).returns(access_token: "new", refresh_token: "new-refresh",
      access_expires_at: 20.minutes.from_now, refresh_expires_at: 40.minutes.from_now)
    SaxoItem.any_instance.expects(:sync_later).never
    RefreshSaxoSessionsJob.perform_now
    assert_equal "new-refresh", item.reload.refresh_token
  end
end
