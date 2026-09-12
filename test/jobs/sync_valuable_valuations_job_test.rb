require "test_helper"

class SyncValuableValuationsJobTest < ActiveJob::TestCase
  setup do
    @account = accounts(:investment).family.accounts.create!(name: "Physical Gold", currency: "USD", balance: 0, accountable: Valuable.new)
    @account.valuable.lots.create!(description: "Bar", acquired_on: Date.current, weight: 10, weight_unit: "gram", karat: 24, cost_amount: 1_000)
  end

  test "refreshes active physical gold accounts with purchases" do
    RefreshValuableValuationJob.expects(:perform_later).with(@account.id)

    SyncValuableValuationsJob.new.perform
  end

  test "retries failed valuation refreshes" do
    ValuableValuation.stubs(:new).raises(ValuableValuation::Error, "provider unavailable")

    assert_enqueued_with(job: RefreshValuableValuationJob, args: [ @account.id ]) do
      RefreshValuableValuationJob.perform_now(@account.id)
    end

    assert_equal 0, DebugLogEntry.count
  end

  test "logs a valuation failure after retries are exhausted" do
    job = RefreshValuableValuationJob.new
    job.instance_variable_set(:@account, @account)
    job.instance_variable_set(:@account_id, @account.id)

    assert_difference "DebugLogEntry.count", 1 do
      job.record_terminal_failure(ValuableValuation::Error.new("provider unavailable"))
    end
  end
end
