require "test_helper"

class Rule::ActionExecutor::AutoDetectMerchantsTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @rule = @family.rules.create!(
      name: "AI merchant rule",
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      actions: [ Rule::Action.new(action_type: "auto_detect_merchants") ]
    )
    @executor = Rule::ActionExecutor::AutoDetectMerchants.new(@rule)
  end

  test "queues one job with every enrichable transaction; the job batches them" do
    use_ai_model_settings(batch_size: 2)
    ids = 5.times.map { |i| create_transaction(account: @account, name: "Coffee #{i}").transaction.id }

    rule_run = RuleRun.create!(rule: @rule, execution_type: "manual", status: "pending", transactions_queued: 5, executed_at: Time.current)

    result = nil
    assert_enqueued_jobs 1, only: Ai::GenerationJob do
      result = @executor.execute(@account.transactions, rule_run:)
    end

    args = enqueued_jobs.last["arguments"].second
    assert_equal [ 0, [] ], args.values_at("cursor", "pending")
    assert_equal ids.sort, Ai::GenerationRun.find(args["run_id"]).items.pluck(:item_id).sort
    assert_equal({ async: true }, result)
    assert_equal [ 1, 5 ], rule_run.reload.values_at(:pending_jobs_count, :transactions_awaiting_ai)
  end

  test "a job the queue refuses, or raises on, stays counted with its run saved for delivery" do
    3.times { |i| create_transaction(account: @account, name: "Coffee #{i}") }
    rule_run = RuleRun.create!(rule: @rule, execution_type: "manual", status: "pending", transactions_queued: 3, executed_at: Time.current)
    Ai::GenerationJob.stubs(:perform_later).returns(false).then.raises(RedisClient::CannotConnectError)

    2.times { assert_equal({ async: true }, @executor.execute(@account.transactions, rule_run:)) }

    assert_equal [ 2, 6 ], rule_run.reload.values_at(:pending_jobs_count, :transactions_awaiting_ai)
    assert_equal 2, Ai::GenerationRun.where.not(next_job: nil).count
  end

  test "a run that can't be saved leaves no count to give back" do
    3.times { |i| create_transaction(account: @account, name: "Coffee #{i}") }
    rule_run = RuleRun.create!(rule: @rule, execution_type: "manual", status: "pending", transactions_queued: 3, executed_at: Time.current)
    Ai::GenerationRun.stubs(:start!).raises(ActiveRecord::StatementInvalid, "connection lost")

    assert_raises(ActiveRecord::StatementInvalid) { @executor.execute(@account.transactions, rule_run:) }
    assert_equal [ 0, 0 ], rule_run.reload.values_at(:pending_jobs_count, :transactions_awaiting_ai)
  end
end
