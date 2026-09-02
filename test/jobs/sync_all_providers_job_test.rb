require "test_helper"

class SyncAllProvidersJobTest < ActiveJob::TestCase
  test "provider-wide sync requests Plaid transaction refreshes before syncing family" do
    family = families(:dylan_family)

    Family.stubs(:find_by).with(id: family.id).returns(family)
    sequence = sequence("provider-wide sync")
    family.expects(:request_plaid_transactions_refreshes_later).with(source: "SyncAllProvidersJob").in_sequence(sequence)
    family.expects(:sync_later).in_sequence(sequence)

    SyncAllProvidersJob.perform_now(family.id)
  end

  test "provider-wide sync continues after refresh orchestration" do
    family = families(:dylan_family)

    Family.stubs(:find_by).with(id: family.id).returns(family)
    PlaidTransactionsRefreshAllJob.stubs(:perform_later).raises(RedisClient::Error, "Redis unavailable")
    family.expects(:sync_later)

    SyncAllProvidersJob.perform_now(family.id)
  end

  test "provider-wide sync ignores a deleted family" do
    Family.expects(:find_by).returns(nil)

    Family.any_instance.expects(:request_plaid_transactions_refreshes_later).never

    SyncAllProvidersJob.perform_now("missing")
  end
end
