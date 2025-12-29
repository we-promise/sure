require "test_helper"

class RuleRunTest < ActiveSupport::TestCase
  setup do
    @rule_run = rule_runs(:one)
  end

  test "complete_job! decrements pending_jobs_count and increments transactions_modified" do
    initial_pending = @rule_run.pending_jobs_count
    initial_modified = @rule_run.transactions_modified

    @rule_run.complete_job!(modified_count: 5)

    assert_equal initial_pending - 1, @rule_run.reload.pending_jobs_count
    assert_equal initial_modified + 5, @rule_run.transactions_modified
  end

  test "complete_job! marks as success when pending_jobs_count reaches zero" do
    @rule_run.update!(pending_jobs_count: 1)

    @rule_run.complete_job!(modified_count: 1)

    assert_equal "success", @rule_run.reload.status
  end

  test "complete_job! merges metadata" do
    @rule_run.update!(run_metadata: { existing_key: "value" })

    @rule_run.complete_job!(modified_count: 1, metadata: {
      job_type: "auto_categorize",
      model: "gpt-4.1",
      total_tokens: 100
    })

    metadata = @rule_run.reload.run_metadata
    assert_equal "value", metadata["existing_key"]
    assert_equal "auto_categorize", metadata["job_type"]
    assert_equal "gpt-4.1", metadata["model"]
    assert_equal 100, metadata["total_tokens"]
  end

  test "merge_metadata! sums numeric values" do
    @rule_run.update!(run_metadata: { total_tokens: 100, prompt_tokens: 50 })

    @rule_run.merge_metadata!({ total_tokens: 50, prompt_tokens: 25, new_key: "value" })

    metadata = @rule_run.reload.run_metadata
    assert_equal 150, metadata["total_tokens"]
    assert_equal 75, metadata["prompt_tokens"]
    assert_equal "value", metadata["new_key"]
  end

  test "merge_metadata! concatenates arrays" do
    @rule_run.update!(run_metadata: { categories: [ "Food", "Shopping" ] })

    @rule_run.merge_metadata!({ categories: [ "Entertainment" ] })

    metadata = @rule_run.reload.run_metadata
    assert_equal [ "Food", "Shopping", "Entertainment" ], metadata["categories"]
  end

  test "merge_metadata! deep merges hashes" do
    @rule_run.update!(run_metadata: {
      llm_usage: { model: "gpt-4.1", tokens: 100 }
    })

    @rule_run.merge_metadata!({
      llm_usage: { tokens: 50, calls: 2 }
    })

    metadata = @rule_run.reload.run_metadata
    assert_equal "gpt-4.1", metadata["llm_usage"]["model"]
    assert_equal 150, metadata["llm_usage"]["tokens"]
    assert_equal 2, metadata["llm_usage"]["calls"]
  end

  test "merge_metadata! handles nil metadata gracefully" do
    @rule_run.complete_job!(modified_count: 1, metadata: nil)

    assert_equal({}, @rule_run.reload.run_metadata)
  end
end
