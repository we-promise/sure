require "test_helper"

class AkahuItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @akahu_item = AkahuItem.create!(
      family: families(:dylan_family),
      name: "Main Akahu",
      app_token: "app-token",
      user_token: "user-token"
    )

    AkahuItem.any_instance.stubs(:perform_post_sync)
    AkahuItem.any_instance.stubs(:broadcast_sync_complete)
  end

  test "failed import result marks sync failed and records health error" do
    AkahuItem.any_instance.stubs(:import_latest_akahu_data).returns(
      success: false,
      error: "Failed to fetch accounts data"
    )

    sync = @akahu_item.syncs.create!

    sync.perform

    sync.reload
    assert_predicate sync, :failed?
    assert_equal "Akahu import: Failed to fetch accounts data", sync.error
    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal "Akahu import: Failed to fetch accounts data", sync.sync_stats.dig("errors", 0, "message")
    assert_equal "sync_error", sync.sync_stats.dig("errors", 0, "category")
  end
end
