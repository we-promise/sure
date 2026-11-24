require "test_helper"

class Rule::ActionExecutor::AutoCategorizeTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @rule = @family.rules.create!(
      name: "AI category rule",
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      actions: [ Rule::Action.new(action_type: "auto_categorize") ]
    )
    @executor = Rule::ActionExecutor::AutoCategorize.new(@rule)
  end

  test "queues one job with every enrichable transaction; the job batches them" do
    use_ai_routes
    use_ai_model_settings(batch_size: 2)
    ids = 3.times.map { |i| create_transaction(account: @account, name: "Coffee #{i}").transaction.id }

    rule_run = RuleRun.create!(rule: @rule, execution_type: "manual", status: "pending", transactions_queued: 3, executed_at: Time.current)
    assert_enqueued_jobs 1, only: Ai::GenerationJob do
      @executor.execute(@account.transactions, rule_run:)
    end

    args = enqueued_jobs.last["arguments"].second
    assert_equal [ 0, [] ], args.values_at("cursor", "pending")
    assert_equal ids.sort, Ai::GenerationRun.find(args["run_id"]).items.pluck(:item_id).sort
    assert_equal [ 1, 3 ], rule_run.reload.values_at(:pending_jobs_count, :transactions_awaiting_ai)
  end

  test "self-hosted label estimates against the resolved categorization model" do
    @family.stubs(:self_hoster?).returns(true)
    LlmUsage.expects(:estimate_auto_categorize_cost).with(
      transaction_count: 20,
      category_count: @family.categories.count,
      model: "jev-latest"
    ).returns(nil)

    use_ai_routes(categorize: %w[jev/jev-latest])
    assert_equal "Auto-categorize transactions with AI (cost: N/A)", @executor.label
  end

  test "self-hosted label reports missing categorization provider" do
    @family.stubs(:self_hoster?).returns(true)
    LlmUsage.expects(:estimate_auto_categorize_cost).never

    use_no_ai
    assert_equal "Auto-categorize transactions with AI (no categorization provider configured)", @executor.label
  end

  test "logs when categorization is blocked by category enrichment protection" do
    transaction = create_transaction(account: @account, name: "Protected transaction").transaction
    transaction.lock_attr!(:category_id)
    @family.expects(:auto_categorize_transactions_later).never

    assert_difference "DebugLogEntry.count", 1 do
      assert_equal 0, @executor.execute(@account.transactions)
    end

    log_entry = DebugLogEntry.order(:created_at).last
    assert_equal "auto_categorization", log_entry.category
    assert_equal "info", log_entry.level
    assert_equal "AI categorization blocked by enrichment protection", log_entry.message
    assert_equal "Rule::ActionExecutor::AutoCategorize", log_entry.source
    assert_equal @family, log_entry.family
    assert_equal @rule.id, log_entry.metadata["rule_id"]
    assert_equal [ transaction.id ], log_entry.metadata["blocked_transaction_ids"]
  end

  test "logs cached AI categories separately from blocked transactions" do
    cached_transaction = create_transaction(account: @account, name: "Cached transaction").transaction
    blocked_transaction = create_transaction(account: @account, name: "Protected transaction").transaction
    category = @family.categories.create!(name: "Coffee")

    cached_transaction.enrich_attribute(:category_id, category.id, source: "ai")
    cached_transaction.lock_attr!(:category_id)
    blocked_transaction.lock_attr!(:category_id)
    @family.expects(:auto_categorize_transactions_later).never

    assert_difference "DebugLogEntry.count", 2 do
      assert_equal 0, @executor.execute(@account.transactions)
    end

    entries = DebugLogEntry.order(:created_at).last(2)
    cache_entry = entries.find { |entry| entry.message == "AI categorization cache used" }
    blocked_entry = entries.find { |entry| entry.message == "AI categorization blocked by enrichment protection" }

    assert_equal "Rule::ActionExecutor::AutoCategorize", cache_entry.source
    assert_equal @family, cache_entry.family
    assert_equal @rule.id, cache_entry.metadata["rule_id"]
    assert_equal [ cached_transaction.id ], cache_entry.metadata["cached_transaction_ids"]

    assert_equal [ blocked_transaction.id ], blocked_entry.metadata["blocked_transaction_ids"]
  end

  test "a job the queue refuses, or raises on, stays counted with its run saved for delivery" do
    3.times { |i| create_transaction(account: @account, name: "Coffee #{i}") }
    rule_run = RuleRun.create!(rule: @rule, execution_type: "manual", status: "pending", transactions_queued: 3, executed_at: Time.current)
    Ai::GenerationJob.stubs(:perform_later).returns(false).then.raises(RedisClient::CannotConnectError)

    2.times { assert_equal({ async: true }, @executor.execute(@account.transactions, rule_run:)) }

    assert_equal [ 2, 6 ], rule_run.reload.values_at(:pending_jobs_count, :transactions_awaiting_ai)
    assert_equal 2, Ai::GenerationRun.where.not(next_job: nil).count
  end
end
