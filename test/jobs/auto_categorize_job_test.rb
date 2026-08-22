require "test_helper"

class AutoCategorizeJobTest < ActiveJob::TestCase
  include EntriesTestHelper, ProviderTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 100, currency: "USD", accountable: Depository.new)
    @family.categories.create!(name: "Food")
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

  test "records unsuccessful provider responses as rule run failures" do
    transaction = create_transaction(account: @account, name: "Coffee shop").transaction
    provider = mock
    provider_error = Provider::Error.new("Fixed prompt tokens exceed context budget")

    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    provider.expects(:auto_categorize).returns(provider_error_response(provider_error))

    assert_difference "DebugLogEntry.count", 1 do
      assert_raises(Family::AutoCategorizer::Error) do
        AutoCategorizeJob.perform_now(@family, transaction_ids: [ transaction.id ], rule_run_id: @rule_run.id)
      end
    end

    @rule_run.reload
    assert_equal "failed", @rule_run.status
    assert_equal "Family::AutoCategorizer::Error: Failed to auto-categorize transactions: Fixed prompt tokens exceed context budget", @rule_run.error_message
    assert_equal 0, @rule_run.pending_jobs_count

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "rule_run", entry.category
    assert_equal "Family::AutoCategorizer::Error", entry.metadata["error_class"]
    assert_equal "Failed to auto-categorize transactions: Fixed prompt tokens exceed context budget", entry.metadata["error_message"]
    assert_equal [ transaction.id ], entry.metadata["transaction_ids"]
  end
end
