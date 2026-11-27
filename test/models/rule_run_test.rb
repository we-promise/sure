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

  test "a failed AI accounting save still lets the run release its count and record the failure" do
    rule_run = create_rule_run(pending_jobs_count: 0)
    rule_run.await_ai!(3)
    rule_run.reload

    assert_raises(ActiveRecord::RecordInvalid) { rule_run.ai_handled!(handled: 1, modified: -1) }
    rule_run.ai_handled!(handled: 3)
    rule_run.fail_job!(error: RuntimeError.new("gave up"), source: "Family::AutoCategorizer")

    assert_equal [ 0, "failed" ], rule_run.reload.values_at(:transactions_awaiting_ai, :status)
  end

  test "a deadlock in the AI accounting save stays a deadlock, so the batch is retried" do
    rule_run = create_rule_run(pending_jobs_count: 0)
    rule_run.await_ai!(3)
    rule_run.reload
    # Postgres aborts the transaction on a deadlock; any query after it fails until rollback.
    def rule_run.save!(*)
      self.class.connection.execute("SELECT 1/0") rescue nil
      raise ActiveRecord::Deadlocked, "deadlock detected"
    end

    assert_raises(ActiveRecord::Deadlocked) do
      ActiveRecord::Base.transaction(requires_new: true) { rule_run.ai_handled!(handled: 1, modified: 1) }
    end
  end

  test "a run that failed after queuing an AI job isn't finished until the job counts its transactions down" do
    rule_run = create_rule_run(pending_jobs_count: 0)
    rule_run.await_ai!(5)   # the AI action queued its job; a later action then raised
    rule_run.update!(status: "failed")
    assert_not rule_run.reload.finished?, "the AI job is still queued"

    rule_run.ai_handled!(handled: 5)
    assert_not rule_run.reload.finished?, "the job hasn't reported back"

    rule_run.complete_job!
    assert rule_run.reload.finished?
  end

  test "a run with a failed job isn't finished while another job is still pending" do
    rule_run = create_rule_run(pending_jobs_count: 2)

    rule_run.fail_job!(error: RuntimeError.new("gave up"), source: "Family::AutoCategorizer")
    assert_not rule_run.reload.finished?, "one job is still running"

    rule_run.complete_job!
    assert rule_run.reload.finished?
    assert rule_run.failed?
  end

  test "fail_job marks run failed and captures debug log entry" do
    rule_run = create_rule_run(pending_jobs_count: 2)
    error = RuntimeError.new("Fixed prompt tokens exceed context budget")
    transaction_id = SecureRandom.uuid

    assert_difference "DebugLogEntry.count", 1 do
      rule_run.fail_job!(error: error, source: "Family::AutoCategorizer", transaction_ids: [ transaction_id ])
    end

    rule_run.reload
    assert_equal "failed", rule_run.status
    assert_equal "RuntimeError: Fixed prompt tokens exceed context budget", rule_run.error_message
    assert_equal 1, rule_run.pending_jobs_count

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "rule_run", entry.category
    assert_equal "error", entry.level
    assert_equal "Family::AutoCategorizer", entry.source
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
      rule_run.fail_job!(error: error, source: "Family::AutoCategorizer")
      rule_run.fail_job!(error: error, source: "Family::AutoCategorizer")
    end

    rule_run.reload
    assert_equal "failed", rule_run.status
    assert_equal 0, rule_run.pending_jobs_count
  end

  test "fail_job deduplicates repeated error messages individually" do
    rule_run = create_rule_run(pending_jobs_count: 3)

    rule_run.fail_job!(error: RuntimeError.new("first failed batch"), source: "Family::AutoCategorizer")
    rule_run.fail_job!(error: RuntimeError.new("second failed batch"), source: "Family::AutoCategorizer")
    rule_run.fail_job!(error: RuntimeError.new("second failed batch"), source: "Family::AutoCategorizer")

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

    rule_run.fail_job!(error: error, source: "Family::AutoCategorizer")
    rule_run.complete_job!(modified_count: 1)

    rule_run.reload
    assert_equal "failed", rule_run.status
    assert_equal "RuntimeError: LLM provider returned HTTP 503", rule_run.error_message
    assert_equal 0, rule_run.pending_jobs_count
    assert_equal 1, rule_run.transactions_modified
  end

  test "an immediate run offers its result once its last job changed something" do
    rule_run = create_rule_run(pending_jobs_count: 2)
    rule_run.update!(execution_type: "immediate")

    RuleRun.expects(:offer_immediate_result).with(@rule.family).once
    rule_run.complete_job!(modified_count: 1)
    rule_run.complete_job!(modified_count: 0)
  end

  test "an immediate run whose jobs changed nothing offers no result" do
    rule_run = create_rule_run(pending_jobs_count: 2)
    rule_run.update!(execution_type: "immediate")

    RuleRun.expects(:offer_immediate_result).never
    rule_run.complete_job!(modified_count: 0)
    rule_run.complete_job!(modified_count: 0)
  end

  test "an immediate run whose last job fails still offers what earlier jobs changed" do
    rule_run = create_rule_run(pending_jobs_count: 2)
    rule_run.update!(execution_type: "immediate")

    RuleRun.expects(:offer_immediate_result).with(@rule.family).once
    rule_run.complete_job!(modified_count: 3)
    rule_run.fail_job!(error: StandardError.new("provider down"), source: "test")

    assert_equal "failed", rule_run.reload.status
  end

  test "retries of a job that already failed don't offer the result again" do
    rule_run = create_rule_run(pending_jobs_count: 2)
    rule_run.update!(execution_type: "immediate")

    RuleRun.expects(:offer_immediate_result).with(@rule.family).once
    rule_run.complete_job!(modified_count: 1)
    3.times { rule_run.fail_job!(error: StandardError.new("provider down"), source: "test") }
  end

  test "a retry that succeeds after the run's only job failed offers what it changed" do
    rule_run = create_rule_run
    rule_run.update!(execution_type: "immediate")

    RuleRun.expects(:offer_immediate_result).with(@rule.family).once
    rule_run.fail_job!(error: StandardError.new("provider down"), source: "test")
    rule_run.complete_job!(modified_count: 2)
  end

  test "an immediate run that fails without changes offers no result" do
    rule_run = create_rule_run
    rule_run.update!(execution_type: "immediate")

    RuleRun.expects(:offer_immediate_result).never
    rule_run.fail_job!(error: StandardError.new("provider down"), source: "test")
  end

  test "a failed result broadcast does not fail the job that finished the run" do
    rule_run = create_rule_run
    rule_run.update!(execution_type: "immediate")
    Family.any_instance.stubs(:broadcast_replace_to).raises(RuntimeError, "cable down")

    assert_nothing_raised { rule_run.complete_job!(modified_count: 1) }
    assert_equal "success", rule_run.reload.status
  end

  test "other runs offer nothing when their jobs finish" do
    rule_run = create_rule_run

    RuleRun.expects(:offer_immediate_result).never
    rule_run.complete_job!(modified_count: 1)
  end

  # A mixed rule's run already holds its other actions' changes, which
  # ApplyImmediateRulesJob has offered.
  test "an immediate mixed run whose AI job changed nothing offers no result again" do
    rule_run = create_rule_run(transactions_modified: 2)
    rule_run.update!(execution_type: "immediate")

    RuleRun.expects(:offer_immediate_result).never
    rule_run.complete_job!
  end

  test "an immediate mixed run whose AI job fails without changes offers no result again" do
    rule_run = create_rule_run(transactions_modified: 2)
    rule_run.update!(execution_type: "immediate")

    RuleRun.expects(:offer_immediate_result).never
    rule_run.fail_job!(error: StandardError.new("provider down"), source: "test")
  end

  test "an immediate mixed run offers what its AI jobs changed" do
    rule_run = create_rule_run(pending_jobs_count: 2, transactions_modified: 2)
    rule_run.update!(execution_type: "immediate")

    RuleRun.expects(:offer_immediate_result).with(@rule.family).once
    rule_run.ai_handled!(handled: 1, modified: 1)
    rule_run.complete_job!
    rule_run.fail_job!(error: StandardError.new("provider down"), source: "test")

    rule_run.reload
    assert_equal 1, rule_run.job_transactions_modified
    assert_equal 3, rule_run.transactions_modified
  end

  test "complete_job never records more modified than the run matched" do
    rule_run = create_rule_run(transactions_modified: 19)

    rule_run.complete_job!(modified_count: 5)

    assert_equal 20, rule_run.reload.transactions_modified
    assert_equal 5, rule_run.job_transactions_modified
  end

  test "ai_handled never records more modified than the run matched" do
    rule_run = create_rule_run(transactions_modified: 19)

    rule_run.ai_handled!(handled: 5, modified: 5)

    assert_equal 20, rule_run.reload.transactions_modified
    assert_equal 5, rule_run.job_transactions_modified
  end

  test "a run blocks nothing while its AI jobs are pending" do
    rule_run = create_rule_run(transactions_modified: 2)

    assert_equal 0, rule_run.transactions_blocked

    rule_run.ai_handled!(handled: 3, modified: 3)
    assert_equal 0, rule_run.reload.transactions_blocked

    rule_run.complete_job!

    assert_equal 15, rule_run.reload.transactions_blocked
  end

  test "a failed run blocks nothing while its other AI jobs are pending" do
    rule_run = create_rule_run(pending_jobs_count: 2, transactions_modified: 2)

    rule_run.fail_job!(error: StandardError.new("provider down"), source: "test")

    assert_equal "failed", rule_run.reload.status
    assert_equal 0, rule_run.transactions_blocked

    rule_run.ai_handled!(handled: 3, modified: 3)
    rule_run.complete_job!

    assert_equal 15, rule_run.reload.transactions_blocked
  end

  private
    def create_rule_run(status: "pending", pending_jobs_count: 1, transactions_modified: 0)
      @rule.rule_runs.create!(
        rule_name: @rule.name,
        execution_type: "manual",
        status: status,
        transactions_queued: 20,
        transactions_processed: 20,
        transactions_modified: transactions_modified,
        pending_jobs_count: pending_jobs_count,
        executed_at: Time.current
      )
    end
end
