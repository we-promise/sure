require "test_helper"

class AutoCategorizeJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @transaction = transactions(:one)
    @rule_run = rules(:one).rule_runs.create!(
      rule_name: rules(:one).name,
      execution_type: "manual",
      status: "pending",
      transactions_queued: 1,
      transactions_processed: 0,
      transactions_modified: 0,
      pending_jobs_count: 1,
      executed_at: Time.current
    )
  end

  test "marks rule run as failed with context when auto-categorization raises" do
    @family.stubs(:auto_categorize_transactions).raises(StandardError, "LLM provider returned HTTP 503")

    assert_raises(StandardError) do
      AutoCategorizeJob.perform_now(@family, transaction_ids: [ @transaction.id ], rule_run_id: @rule_run.id)
    end

    @rule_run.reload

    assert_equal "failed", @rule_run.status
    assert_equal 0, @rule_run.pending_jobs_count
    assert_includes @rule_run.error_message, "Auto-categorization failed"
    assert_includes @rule_run.error_message, "LLM provider returned HTTP 503"
    assert_includes @rule_run.error_message, @transaction.id.to_s
  end
end
