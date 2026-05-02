require "test_helper"

class RuleRunTest < ActiveSupport::TestCase
  test "transactions_blocked returns queued minus processed" do
    run = RuleRun.new(
      rule: rules(:one),
      execution_type: "manual",
      status: "success",
      executed_at: Time.current,
      transactions_queued: 10,
      transactions_processed: 7,
      transactions_modified: 3,
      pending_jobs_count: 0
    )

    assert_equal 3, run.transactions_blocked
  end

  test "transactions_blocked never goes negative" do
    run = RuleRun.new(
      rule: rules(:one),
      execution_type: "manual",
      status: "success",
      executed_at: Time.current,
      transactions_queued: 5,
      transactions_processed: 8,
      transactions_modified: 5,
      pending_jobs_count: 0
    )

    assert_equal 0, run.transactions_blocked
  end
end
