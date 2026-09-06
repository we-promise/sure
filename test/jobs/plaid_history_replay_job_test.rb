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

  # The check, the reset and the enqueue have to be one atomic step. Split up, a
  # sync created after the check reads the old cursor, absorbs this request via
  # sync_later's coalescing, and then writes its cursor back over the reset —
  # leaving history unreplayed with nothing queued to retry.
  test "checks, resets and queues under a single row lock" do
    locked_during_reset = false

    @plaid_item.define_singleton_method(:with_lock) do |&block|
      locked_during_reset = true
      block.call
    end

    PlaidHistoryReplayJob.perform_now(@plaid_item)

    assert locked_during_reset, "the cursor reset must happen while holding the item lock"
    assert_nil @plaid_item.reload.next_cursor
  end

  # A sync that appears between the caller's decision and this job running is the
  # ordinary case, not the race: the job simply defers and the cursor survives to
  # be reset on a later attempt.
  test "a sync appearing before the reset defers the replay intact" do
    @plaid_item.syncs.create!.start!

    PlaidHistoryReplayJob.perform_now(@plaid_item, attempts_remaining: 1)

    assert_equal "cursor-before-replay", @plaid_item.reload.next_cursor
    assert_enqueued_jobs 1, only: PlaidHistoryReplayJob
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
