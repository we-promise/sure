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

  test "records rule run failure debug log before reraising merchant detection errors" do
    @family.stubs(:auto_detect_transaction_merchants).raises(StandardError, "Invalid JSON in provider response")

    assert_difference "DebugLogEntry.count", 1 do
      assert_raises(StandardError) do
        AutoDetectMerchantsJob.perform_now(@family, transaction_ids: [ @transaction.id ], rule_run_id: @rule_run.id)
      end
    end

    @rule_run.reload

    assert_equal "failed", @rule_run.status
    assert_equal 0, @rule_run.pending_jobs_count
    assert_equal "StandardError: Invalid JSON in provider response", @rule_run.error_message

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "rule_run", entry.category
    assert_equal "error", entry.level
    assert_equal "AutoDetectMerchantsJob", entry.source
    assert_equal @family, entry.family
    assert_equal @rule_run.id, entry.metadata["rule_run_id"]
    assert_equal [ @transaction.id ], entry.metadata["transaction_ids"]
  end
end
