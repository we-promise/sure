require "test_helper"

class PlaidTransactionsRefreshJobTest < ActiveJob::TestCase
  setup do
    @plaid_item = plaid_items(:one)
    @plaid_item.update!(next_cursor: "saved-cursor")
    @provider = mock
    PlaidItem.any_instance.stubs(:plaid_provider).returns(@provider)
  end

  test "requests refresh and schedules cursor polling" do
    @provider.expects(:refresh_transactions).with(@plaid_item.access_token)

    assert_enqueued_with(
      job: PlaidTransactionsRefreshPollJob,
      args: [ @plaid_item, { cursor: "saved-cursor" } ]
    ) do
      PlaidTransactionsRefreshJob.perform_now(@plaid_item)
    end
  end

  test "still polls after an ambiguous refresh request failure" do
    @provider.expects(:refresh_transactions).raises(Timeout::Error)

    assert_difference "DebugLogEntry.count", 1 do
      assert_enqueued_with(job: PlaidTransactionsRefreshPollJob) do
        PlaidTransactionsRefreshJob.perform_now(@plaid_item)
      end
    end

    assert_equal "Timeout::Error", DebugLogEntry.order(:created_at).last.metadata["error_class"]
  end
end
