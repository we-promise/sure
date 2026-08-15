require "test_helper"

class AutoCategorizeJobTest < ActiveJob::TestCase
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
    @rule_run = @rule.rule_runs.create!(
      rule_name: @rule.name,
      execution_type: "manual",
      status: "pending",
      transactions_queued: 20,
      transactions_processed: 20,
      transactions_modified: 0,
      pending_jobs_count: 1,
      executed_at: Time.current
    )
  end

  test "records rule run failure debug log before reraising categorization errors" do
    error = RuntimeError.new("Fixed prompt tokens exceed context budget")
    transaction_ids = [ SecureRandom.uuid ]

    @family.stubs(:auto_categorize_transactions).with(transaction_ids).raises(error)

    assert_difference "DebugLogEntry.count", 1 do
      assert_raises(RuntimeError) do
        AutoCategorizeJob.perform_now(@family, transaction_ids: transaction_ids, rule_run_id: @rule_run.id)
      end
    end

    @rule_run.reload
    assert_equal "failed", @rule_run.status
    assert_equal "RuntimeError: Fixed prompt tokens exceed context budget", @rule_run.error_message
    assert_equal 0, @rule_run.pending_jobs_count

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "rule_run", entry.category
    assert_equal "error", entry.level
    assert_equal "AutoCategorizeJob", entry.source
    assert_equal @family, entry.family
    assert_equal @rule_run.id, entry.metadata["rule_run_id"]
    assert_equal transaction_ids, entry.metadata["transaction_ids"]
  end
end
