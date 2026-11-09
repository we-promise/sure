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

    assert_equal ids.sort, enqueued_jobs.last["arguments"].second["ids"].sort
    assert_equal({ async: true, modified_count: 5, jobs_count: 1 }, result)
    assert_equal 5, rule_run.reload.transactions_awaiting_ai
  end
end
