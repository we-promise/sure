require "test_helper"

class PlaidHistoryReplayJobTest < ActiveJob::TestCase
  setup do
    @plaid_item = plaid_items(:one)
    @plaid_item.syncs.destroy_all
    @plaid_item.update!(next_cursor: "cursor-before-replay")
  end

  test "clears the cursor and syncs when no sync is in flight" do
    PlaidHistoryReplayJob.perform_now(@plaid_item)

    assert_nil @plaid_item.reload.next_cursor
    assert @plaid_item.syncs.any?, "a sync should have been queued to replay history"
  end

  # The reset has to wait: an active sync read the old cursor before the
  # preference changed and writes its own cursor back on completion, which would
  # erase an inline reset and leave history unreplayed.
  test "leaves the cursor alone and reschedules while a sync is active" do
    active_sync = @plaid_item.syncs.create!
    active_sync.start!

    assert_enqueued_with job: PlaidHistoryReplayJob do
      PlaidHistoryReplayJob.perform_now(@plaid_item, attempts_remaining: 1)
    end

    assert_equal "cursor-before-replay", @plaid_item.reload.next_cursor
  end

  test "waits on an incomplete sync that is already hidden from the UI" do
    active_sync = @plaid_item.syncs.create!(created_at: Sync::VISIBLE_FOR.ago - 1.minute)
    active_sync.start!

    assert_enqueued_with job: PlaidHistoryReplayJob do
      PlaidHistoryReplayJob.perform_now(@plaid_item, attempts_remaining: 1)
    end

    assert_equal "cursor-before-replay", @plaid_item.reload.next_cursor
  end

  test "captures exhausted retries for support" do
    active_sync = @plaid_item.syncs.create!
    active_sync.start!

    assert_difference "DebugLogEntry.count", 1 do
      PlaidHistoryReplayJob.perform_now(@plaid_item, attempts_remaining: 0)
    end

    assert_equal "cursor-before-replay", @plaid_item.reload.next_cursor
  end
end
