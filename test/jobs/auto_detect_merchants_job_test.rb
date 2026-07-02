require "test_helper"

class AutoDetectMerchantsJobTest < ActiveJob::TestCase
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

  test "marks rule run as failed with context when merchant detection raises" do
    @family.stubs(:auto_detect_transaction_merchants).raises(StandardError, "Invalid JSON in provider response")

    assert_raises(StandardError) do
      AutoDetectMerchantsJob.perform_now(@family, transaction_ids: [ @transaction.id ], rule_run_id: @rule_run.id)
    end

    @rule_run.reload

    assert_equal "failed", @rule_run.status
    assert_equal 0, @rule_run.pending_jobs_count
    assert_includes @rule_run.error_message, "Merchant auto-detection failed"
    assert_includes @rule_run.error_message, "Invalid JSON in provider response"
    assert_includes @rule_run.error_message, @transaction.id.to_s
  end
end
