require "test_helper"

class SyncAllJobTest < ActiveJob::TestCase
  test "scheduled sync requests Plaid transaction refreshes before syncing families" do
    family = families(:dylan_family)
    Family.stubs(:find_each).yields(family)
    sequence = sequence("scheduled sync")
    family.expects(:request_plaid_transactions_refreshes_later).with(source: "SyncAllJob").in_sequence(sequence)
    family.expects(:sync_later).in_sequence(sequence)

    SyncAllJob.perform_now
  end

  test "scheduled sync continues after refresh orchestration" do
    family = families(:dylan_family)
    Family.stubs(:find_each).yields(family)
    PlaidTransactionsRefreshAllJob.stubs(:perform_later).raises(RedisClient::Error, "Redis unavailable")
    family.expects(:sync_later)

    SyncAllJob.perform_now
  end
end
