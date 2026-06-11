require "test_helper"

class RuleRunTest < ActiveSupport::TestCase
  test "complete_job! preserves failed status and error message" do
    rule_run = rules(:one).rule_runs.create!(
      rule_name: rules(:one).name,
      execution_type: "manual",
      status: "pending",
      transactions_queued: 2,
      transactions_processed: 0,
      transactions_modified: 0,
      pending_jobs_count: 2,
      executed_at: Time.current
    )

    rule_run.fail_job!(error_message: "LLM provider returned HTTP 503")
    rule_run.complete_job!(modified_count: 1)
    rule_run.reload

    assert_equal "failed", rule_run.status
    assert_equal "LLM provider returned HTTP 503", rule_run.error_message
    assert_equal 0, rule_run.pending_jobs_count
    assert_equal 1, rule_run.transactions_modified
  end
end
