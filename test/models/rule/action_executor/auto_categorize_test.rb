require "test_helper"

class Rule::ActionExecutor::AutoCategorizeTest < ActiveSupport::TestCase
  include EntriesTestHelper

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
end
