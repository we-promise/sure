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
    assert_equal({ async: true, modified_count: 5 }, result)
    assert_equal [ 1, 5 ], rule_run.reload.values_at(:pending_jobs_count, :transactions_awaiting_ai)
  end

  test "a job that can't be queued stops the run waiting for its transactions" do
    3.times { |i| create_transaction(account: @account, name: "Coffee #{i}") }
    rule_run = RuleRun.create!(rule: @rule, execution_type: "manual", status: "pending", transactions_queued: 3, executed_at: Time.current)
    Ai::GenerationJob.stubs(:perform_later).returns(false)

    assert_raises(ActiveJob::EnqueueError) { @executor.execute(@account.transactions, rule_run:) }
    assert_equal 0, rule_run.reload.transactions_awaiting_ai
  end

  test "a job whose enqueue raises stops the run waiting for its transactions" do
    3.times { |i| create_transaction(account: @account, name: "Coffee #{i}") }
    rule_run = RuleRun.create!(rule: @rule, execution_type: "manual", status: "pending", transactions_queued: 3, executed_at: Time.current)
    Ai::GenerationJob.stubs(:perform_later).raises(RedisClient::CannotConnectError)

    assert_raises(RedisClient::CannotConnectError) { @executor.execute(@account.transactions, rule_run:) }
    assert_equal 0, rule_run.reload.transactions_awaiting_ai
  end

  test "a release that fails while the enqueue fails keeps the enqueue error" do
    create_transaction(account: @account, name: "Coffee")
    rule_run = RuleRun.create!(rule: @rule, execution_type: "manual", status: "pending", transactions_queued: 1, executed_at: Time.current)
    Ai::GenerationJob.stubs(:perform_later).raises(RedisClient::CannotConnectError)
    RuleRun.any_instance.expects(:release_ai_job!).raises(ActiveRecord::StatementInvalid, "connection lost")

    assert_raises(RedisClient::CannotConnectError) { @executor.execute(@account.transactions, rule_run:) }
  end
end
