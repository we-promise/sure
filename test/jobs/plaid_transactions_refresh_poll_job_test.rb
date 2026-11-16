require "test_helper"

class PlaidTransactionsRefreshPollJobTest < ActiveJob::TestCase
  setup do
    @plaid_item = plaid_items(:one)
    @plaid_item.update!(next_cursor: "saved-cursor")
    @provider = mock
    PlaidItem.any_instance.stubs(:plaid_provider).returns(@provider)
  end

  test "continues polling from a cursor advanced by a concurrent sync" do
    @plaid_item.update!(next_cursor: "advanced-cursor")
    @provider.expects(:get_transactions)
      .with(@plaid_item.access_token, next_cursor: "advanced-cursor")
      .returns(stub(cursor: "refreshed-cursor"))

    assert_enqueued_with(job: SyncJob) do
      perform_enqueued_jobs(only: PlaidTransactionsRefreshFollowUpSyncJob) do
        PlaidTransactionsRefreshPollJob.perform_now(@plaid_item, cursor: "saved-cursor")
      end
    end
  end

  test "schedules normal sync when refreshed deltas are available" do
    @provider.expects(:get_transactions)
      .with(@plaid_item.access_token, next_cursor: "saved-cursor")
      .returns(stub(cursor: "advanced-cursor"))

    assert_enqueued_with(job: PlaidTransactionsRefreshFollowUpSyncJob) do
      PlaidTransactionsRefreshPollJob.perform_now(@plaid_item, cursor: "saved-cursor")
    end
  end

  test "polls again while the cursor has not advanced" do
    @provider.expects(:get_transactions).returns(stub(cursor: "saved-cursor"))

    assert_enqueued_with(
      job: PlaidTransactionsRefreshPollJob,
      args: [ @plaid_item, { cursor: "saved-cursor", attempts_remaining: 1 } ]
    ) do
      PlaidTransactionsRefreshPollJob.perform_now(
        @plaid_item,
        cursor: "saved-cursor",
        attempts_remaining: 2
      )
    end
  end

  test "falls back to normal sync when polling is exhausted" do
    @provider.expects(:get_transactions).returns(stub(cursor: "saved-cursor"))

    assert_difference "DebugLogEntry.count", 1 do
      assert_enqueued_with(job: PlaidTransactionsRefreshFollowUpSyncJob) do
        PlaidTransactionsRefreshPollJob.perform_now(
          @plaid_item,
          cursor: "saved-cursor",
          attempts_remaining: 1
        )
      end
    end
  end

  test "falls back to normal sync when polling fails" do
    @provider.expects(:get_transactions).raises(Plaid::ApiError.new(code: 500))

    assert_difference "DebugLogEntry.count", 1 do
      assert_enqueued_with(job: PlaidTransactionsRefreshFollowUpSyncJob) do
        PlaidTransactionsRefreshPollJob.perform_now(@plaid_item, cursor: "saved-cursor")
      end
    end
  end
end
