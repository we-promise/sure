require "test_helper"

class AutoCategorizeJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @rule_run = rule_runs(:one)
  end

  test "passes metadata to rule_run when result includes metadata" do
    result = Family::AutoCategorizer::Result.new(
      modified_count: 5,
      metadata: {
        job_type: "auto_categorize",
        model: "gpt-4.1",
        total_tokens: 100,
        transactions_categorized: 5
      }
    )

    @family.stubs(:auto_categorize_transactions).returns(result)
    @rule_run.update!(pending_jobs_count: 1, run_metadata: {})

    AutoCategorizeJob.perform_now(@family, transaction_ids: [], rule_run_id: @rule_run.id)

    @rule_run.reload
    assert_equal "success", @rule_run.status
    assert_equal 5, @rule_run.transactions_modified
    assert_equal "auto_categorize", @rule_run.run_metadata["job_type"]
    assert_equal "gpt-4.1", @rule_run.run_metadata["model"]
    assert_equal 100, @rule_run.run_metadata["total_tokens"]
  end

  test "handles integer result for backwards compatibility" do
    @family.stubs(:auto_categorize_transactions).returns(3)
    @rule_run.update!(pending_jobs_count: 1, run_metadata: {})

    AutoCategorizeJob.perform_now(@family, transaction_ids: [], rule_run_id: @rule_run.id)

    @rule_run.reload
    assert_equal "success", @rule_run.status
    assert_equal 3, @rule_run.transactions_modified
    assert_equal({}, @rule_run.run_metadata)
  end

  test "works without rule_run_id" do
    result = Family::AutoCategorizer::Result.new(modified_count: 2, metadata: {})
    @family.stubs(:auto_categorize_transactions).returns(result)

    # Should not raise
    AutoCategorizeJob.perform_now(@family, transaction_ids: [])
  end
end
