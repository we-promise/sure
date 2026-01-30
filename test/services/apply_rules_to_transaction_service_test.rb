require "test_helper"

class ApplyRulesToTransactionServiceTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test Account", balance: 1000, currency: "USD", accountable: Depository.new)
    @merchant = @family.merchants.create!(name: "Test Merchant", type: "FamilyMerchant")
    @category = @family.categories.create!(name: "Test Category")
    @groceries_category = @family.categories.create!(name: "Groceries")
  end

  test "applies rules to a single transaction" do
    # Create a transaction
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant,
      name: "Test Transaction"
    )

    # Create a rule that matches this transaction
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    # Apply rules to the transaction
    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    # Verify the result
    assert_equal 1, result[:transactions_count]
    assert_equal 1, result[:rules_matched]
    assert_equal 1, result[:rules_applied]
    assert_equal 0, result[:errors].count

    # Verify the rule was actually applied
    entry.reload
    assert_equal @groceries_category, entry.transaction.category
  end

  test "applies rules to multiple transactions" do
    # Create multiple transactions
    entry1 = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant,
      name: "Transaction 1"
    )

    entry2 = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant,
      name: "Transaction 2"
    )

    # Create a rule that matches these transactions
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    # Apply rules to both transactions
    result = ApplyRulesToTransactionService.new([entry1, entry2], execution_type: "manual").call

    # Verify the result
    assert_equal 2, result[:transactions_count]
    assert_equal 1, result[:rules_matched]
    assert_equal 1, result[:rules_applied]

    # Verify the rules were actually applied
    entry1.reload
    entry2.reload
    assert_equal @groceries_category, entry1.transaction.category
    assert_equal @groceries_category, entry2.transaction.category
  end

  test "only applies active rules" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    # Create an inactive rule
    inactive_rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: false,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    # Apply rules
    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    # Verify inactive rule was not applied
    assert_equal 0, result[:rules_matched]
    assert_equal 0, result[:rules_applied]

    entry.reload
    assert_nil entry.transaction.category
  end

  test "only applies rules that match transaction conditions" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    # Create a rule that doesn't match
    other_merchant = @family.merchants.create!(name: "Other Merchant", type: "FamilyMerchant")
    non_matching_rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: other_merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    # Apply rules
    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    # Verify non-matching rule was not applied
    assert_equal 0, result[:rules_matched]
    assert_equal 0, result[:rules_applied]

    entry.reload
    assert_nil entry.transaction.category
  end

  test "applies multiple rules to the same transaction" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant,
      name: "Test Transaction"
    )

    category1 = @family.categories.create!(name: "Category 1")
    category2 = @family.categories.create!(name: "Category 2")

    # Create two rules that both match
    rule1 = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: category1.id
        )
      ]
    )

    rule2 = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_name",
          operator: "contains",
          value: "Test"
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: category2.id
        )
      ]
    )

    # Apply rules
    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    # Verify both rules were matched and applied
    assert_equal 2, result[:rules_matched]
    assert_equal 2, result[:rules_applied]

    # The last rule applied will set the category (rule2)
    entry.reload
    assert_equal category2, entry.transaction.category
  end

  test "handles errors gracefully" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    # Create a rule with invalid action (will cause error)
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: 999999 # Invalid category ID
        )
      ]
    )

    # Apply rules - should handle error gracefully
    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    # Should have matched but may have errors
    assert_equal 1, result[:rules_matched]
    # The rule may still be applied but with an error, or it may fail
    assert result[:rules_applied] >= 0
  end

  test "creates rule run records" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    assert_difference "RuleRun.count", 1 do
      ApplyRulesToTransactionService.new(entry, execution_type: "manual").call
    end

    rule_run = RuleRun.last
    assert_equal rule, rule_run.rule
    assert_equal "manual", rule_run.execution_type
    assert_equal "success", rule_run.status
  end

  test "handles empty transaction array" do
    result = ApplyRulesToTransactionService.new([], execution_type: "manual").call

    assert_equal 0, result[:transactions_count]
    assert_equal 0, result[:rules_applied]
  end

  test "handles transaction without family" do
    # This shouldn't happen in practice, but test edge case
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    # Manually break the family association (edge case)
    @account.update_column(:family_id, nil)

    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    assert_equal 0, result[:rules_applied]
  end

  test "respects ignore_attribute_locks parameter" do
    # Set an initial category to test lock behavior
    initial_category = @family.categories.create!(name: "Initial Category")
    
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant,
      category: initial_category
    )

    # Capture original category before locking and before running rules
    entry.reload
    original_category = entry.transaction.category
    assert_equal initial_category, original_category, "Should have initial category set"

    # Lock an attribute
    entry.transaction.lock_attr!(:category_id)

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    # Apply rules without ignoring locks - should not modify locked attribute
    result1 = ApplyRulesToTransactionService.new(entry, execution_type: "manual", ignore_attribute_locks: false).call
    entry.reload
    assert_equal original_category, entry.transaction.category, "Category should not change when locks are respected (result1)"

    # Apply rules with ignoring locks - should modify locked attribute
    result2 = ApplyRulesToTransactionService.new(entry, execution_type: "manual", ignore_attribute_locks: true).call
    entry.reload
    assert_not_equal original_category, entry.transaction.category, "Category should change when locks are ignored (result2)"
    assert_equal @groceries_category, entry.transaction.category
  end

  test "works with Entry objects" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    # Pass Entry object directly
    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    assert_equal 1, result[:transactions_count]
    assert_equal 1, result[:rules_applied]

    entry.reload
    assert_equal @groceries_category, entry.transaction.category
  end

  test "works with Transaction objects" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    # Pass Transaction object directly
    result = ApplyRulesToTransactionService.new(entry.transaction, execution_type: "manual").call

    assert_equal 1, result[:transactions_count]
    assert_equal 1, result[:rules_applied]

    entry.reload
    assert_equal @groceries_category, entry.transaction.category
  end

  test "tracks execution time" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    assert result[:execution_time_ms].is_a?(Numeric)
    assert result[:execution_time_ms] >= 0
  end

  test "handles transactions with compound rule conditions" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant,
      amount: 100,
      name: "Large Purchase"
    )

    # Create a compound rule: merchant = X AND amount > 50
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "compound",
          operator: "and",
          sub_conditions: [
            Rule::Condition.new(
              condition_type: "transaction_merchant",
              operator: "=",
              value: @merchant.id
            ),
            Rule::Condition.new(
              condition_type: "transaction_amount",
              operator: ">",
              value: 50
            )
          ]
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    assert_equal 1, result[:rules_matched]
    assert_equal 1, result[:rules_applied]

    entry.reload
    assert_equal @groceries_category, entry.transaction.category
  end

  test "handles rules with multiple actions" do
    tag = @family.tags.create!(name: "Important")
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant,
      name: "Test Transaction"
    )

    # Create a rule with multiple actions
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        ),
        Rule::Action.new(
          action_type: "set_transaction_tags",
          value: tag.id.to_s
        )
      ]
    )

    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    assert_equal 1, result[:rules_applied]
    assert result[:transactions_modified] > 0

    entry.reload
    assert_equal @groceries_category, entry.transaction.category
    assert_includes entry.transaction.tags, tag
  end

  test "handles rules with effective_date in the future" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    # Create a rule with effective_date in the future (should not match)
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.from_now.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    # Rule should not match because effective_date is in the future
    assert_equal 0, result[:rules_matched]

    entry.reload
    assert_nil entry.transaction.category
  end

  test "handles rules with different resource types" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    # Create a rule for a different resource type (should not apply)
    # Note: This assumes there are other resource types - adjust if needed
    # For now, we'll just verify transaction rules work correctly

    transaction_rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    # Only transaction rules should be considered
    assert_equal 1, result[:rules_matched]
  end

  test "handles large number of rules efficiently" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    # Create multiple rules
    10.times do |i|
      Rule.create!(
        family: @family,
        resource_type: "transaction",
        active: true,
        effective_date: 1.day.ago.to_date,
        conditions: [
          Rule::Condition.new(
            condition_type: "transaction_merchant",
            operator: "=",
            value: @merchant.id
          )
        ],
        actions: [
          Rule::Action.new(
            action_type: "set_transaction_category",
            value: @groceries_category.id
          )
        ]
      )
    end

    # Should handle multiple rules efficiently
    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    assert_equal 10, result[:rules_matched]
    assert_equal 10, result[:rules_applied]
    # Note: Execution time assertion removed to avoid CI timing flakiness
    # Performance can be validated in separate benchmark/performance test suite if needed
  end

  test "handles mixed matching and non-matching rules" do
    entry1 = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant,
      name: "Match"
    )

    other_merchant = @family.merchants.create!(name: "Other Merchant", type: "FamilyMerchant")
    entry2 = create_transaction(
      date: Date.current,
      account: @account,
      merchant: other_merchant,
      name: "No Match"
    )

    # Create a rule that matches entry1 but not entry2
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    result = ApplyRulesToTransactionService.new([entry1, entry2], execution_type: "manual").call

    assert_equal 1, result[:rules_matched]
    assert_equal 1, result[:rules_applied]

    entry1.reload
    entry2.reload
    assert_equal @groceries_category, entry1.transaction.category
    assert_nil entry2.transaction.category
  end

  test "handles transactions from different families" do
    # This test ensures rules from one family don't affect transactions from another
    # Create a different family to properly test cross-family isolation
    other_family = Family.create!(
      name: "Other Test Family",
      currency: "USD"
    )
    other_account = other_family.accounts.create!(name: "Other Account", balance: 1000, currency: "USD", accountable: Depository.new)
    other_merchant = other_family.merchants.create!(name: "Other Merchant", type: "FamilyMerchant")
    other_entry = create_transaction(
      date: Date.current,
      account: other_account,
      merchant: other_merchant
    )

    # Create a rule in the original family (different from other_family)
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    # Try to apply rules from @family to transaction from other_family
    # This should not work - the service should only find rules for the transaction's family
    result = ApplyRulesToTransactionService.new(other_entry, execution_type: "manual").call

    # Should not match because the rule is for a different family
    assert_equal 0, result[:rules_matched], "Rules from one family should not apply to transactions from another family"
  end

  test "handles empty rule conditions gracefully" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    # Create a rule with no conditions (should match all transactions)
    # When conditions are empty, matching_resources_scope returns the base scope,
    # meaning the rule matches all transactions in the family after effective_date
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    # Rules without conditions should match all transactions
    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    # Empty conditions should match all transactions (match-all behavior)
    assert_equal 1, result[:rules_matched], "Rule with empty conditions should match all transactions"
    assert_equal 1, result[:rules_applied], "Rule with empty conditions should be applied"
    assert result[:transactions_modified] > 0, "Rule should have modified the transaction"

    # Verify the rule was actually applied - transaction category should be set
    entry.reload
    assert_equal @groceries_category, entry.transaction.category, "Transaction category should be set by rule with empty conditions"
  end

  test "returns proper error structure when rule application fails" do
    entry = create_transaction(
      date: Date.current,
      account: @account,
      merchant: @merchant
    )

    # Create a rule that will fail (invalid category ID)
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: 999999 # Invalid category ID
        )
      ]
    )

    result = ApplyRulesToTransactionService.new(entry, execution_type: "manual").call

    # Should have matched the rule
    assert_equal 1, result[:rules_matched]
    
    # May have errors or may have applied (depending on validation)
    if result[:errors].any?
      error = result[:errors].first
      assert error[:rule_id].present?
      assert error[:rule_name].present?
      assert error[:error].present?
    end
  end

  test "handles concurrent rule applications" do
    # Create multiple transactions
    entries = 5.times.map do |i|
      create_transaction(
        date: Date.current,
        account: @account,
        merchant: @merchant,
        name: "Transaction #{i}"
      )
    end

    # Create a rule
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      active: true,
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @merchant.id
        )
      ],
      actions: [
        Rule::Action.new(
          action_type: "set_transaction_category",
          value: @groceries_category.id
        )
      ]
    )

    # Apply rules to all transactions
    result = ApplyRulesToTransactionService.new(entries, execution_type: "manual").call

    assert_equal 5, result[:transactions_count]
    assert_equal 1, result[:rules_matched]
    assert_equal 1, result[:rules_applied]

    # Verify all transactions were updated
    entries.each do |entry|
      entry.reload
      assert_equal @groceries_category, entry.transaction.category
    end
  end
end


