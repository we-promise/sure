require "test_helper"

class RuleRunTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @rule = @family.rules.create!(
      name: "AI category rule",
      resource_type: "transaction",
      effective_date: 1.year.ago.to_date,
      conditions: [
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "coffee")
      ],
      actions: [
        Rule::Action.new(action_type: "auto_categorize")
      ]
    )
  end

  test "fail_job marks run failed and captures debug log entry" do
    rule_run = create_rule_run(pending_jobs_count: 2)
    error = RuntimeError.new("Fixed prompt tokens exceed context budget")
    transaction_id = SecureRandom.uuid

    assert_difference "DebugLogEntry.count", 1 do
      rule_run.fail_job!(error: error, source: "AutoCategorizeJob", transaction_ids: [ transaction_id ])
    end

    rule_run.reload
    assert_equal "failed", rule_run.status
    assert_equal "RuntimeError: Fixed prompt tokens exceed context budget", rule_run.error_message
    assert_equal 1, rule_run.pending_jobs_count

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "rule_run", entry.category
    assert_equal "error", entry.level
    assert_equal "AutoCategorizeJob", entry.source
    assert_equal @family, entry.family
    assert_equal rule_run.id, entry.metadata["rule_run_id"]
    assert_equal @rule.id, entry.metadata["rule_id"]
    assert_equal @rule.name, entry.metadata["rule_name"]
    assert_equal "RuntimeError", entry.metadata["error_class"]
    assert_equal "Fixed prompt tokens exceed context budget", entry.metadata["error_message"]
    assert_equal 1, entry.metadata["transaction_count"]
    assert_equal [ transaction_id ], entry.metadata["transaction_ids"]
  end

  test "fail_job is retry-safe for pending count and debug logging" do
    rule_run = create_rule_run(pending_jobs_count: 1)
    error = RuntimeError.new("retrying same failed batch")

    assert_difference "DebugLogEntry.count", 1 do
      rule_run.fail_job!(error: error, source: "AutoCategorizeJob")
      rule_run.fail_job!(error: error, source: "AutoCategorizeJob")
    end

    rule_run.reload
    assert_equal "failed", rule_run.status
    assert_equal 0, rule_run.pending_jobs_count
  end

  test "fail_job deduplicates repeated error messages individually" do
    rule_run = create_rule_run(pending_jobs_count: 3)

    rule_run.fail_job!(error: RuntimeError.new("first failed batch"), source: "AutoCategorizeJob")
    rule_run.fail_job!(error: RuntimeError.new("second failed batch"), source: "AutoCategorizeJob")
    rule_run.fail_job!(error: RuntimeError.new("second failed batch"), source: "AutoCategorizeJob")

    rule_run.reload
    assert_equal "RuntimeError: first failed batch\nRuntimeError: second failed batch", rule_run.error_message
    assert_equal 0, rule_run.pending_jobs_count
  end

  test "complete_job does not overwrite failed status" do
    rule_run = create_rule_run(status: "failed", pending_jobs_count: 0)

    rule_run.complete_job!(modified_count: 3)

    rule_run.reload
    assert_equal "failed", rule_run.status
    assert_equal 0, rule_run.pending_jobs_count
    assert_equal 3, rule_run.transactions_modified
  end

  test "complete_job preserves failure while remaining jobs finish" do
    rule_run = create_rule_run(pending_jobs_count: 2)
    error = RuntimeError.new("LLM provider returned HTTP 503")

    rule_run.fail_job!(error: error, source: "AutoCategorizeJob")
    rule_run.complete_job!(modified_count: 1)

    rule_run.reload
    assert_equal "failed", rule_run.status
    assert_equal "RuntimeError: LLM provider returned HTTP 503", rule_run.error_message
    assert_equal 0, rule_run.pending_jobs_count
    assert_equal 1, rule_run.transactions_modified
  end

  private
    def create_rule_run(status: "pending", pending_jobs_count: 1)
      @rule.rule_runs.create!(
        rule_name: @rule.name,
        execution_type: "manual",
        status: status,
        transactions_queued: 20,
        transactions_processed: 20,
        transactions_modified: 0,
        pending_jobs_count: pending_jobs_count,
        executed_at: Time.current
      )
    end
end
