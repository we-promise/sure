require "test_helper"

class Rule::ConditionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @transaction_rule = rules(:one)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)

    @grocery_category = @family.categories.create!(name: "Grocery")
    @whole_foods_merchant = @family.merchants.create!(name: "Whole Foods", type: "FamilyMerchant")

    # Some sample transactions to work with
    create_transaction(date: Date.current, account: @account, amount: 100, name: "Rule test transaction1", merchant: @whole_foods_merchant)
    create_transaction(date: Date.current, account: @account, amount: -200, name: "Rule test transaction2")
    create_transaction(date: 1.day.ago.to_date, account: @account, amount: 50, name: "Rule test transaction3")
    create_transaction(date: 1.year.ago.to_date, account: @account, amount: 10, name: "Rule test transaction4", merchant: @whole_foods_merchant)
    create_transaction(date: 1.year.ago.to_date, account: @account, amount: 1000, name: "Rule test transaction5")

    @rule_scope = @account.transactions
  end

  test "applies transaction_name condition" do
    scope = @rule_scope

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_name",
      operator: "=",
      value: "Rule test transaction1"
    )

    scope = condition.prepare(scope)

    assert_equal 5, scope.count

    filtered = condition.apply(scope)

    assert_equal 1, filtered.count
  end

  test "applies transaction_amount condition using absolute values" do
    scope = @rule_scope

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_amount",
      operator: ">",
      value: "50"
    )

    scope = condition.prepare(scope)

    filtered = condition.apply(scope)
    assert_equal 3, filtered.count
  end

  test "applies transaction_merchant condition" do
    scope = @rule_scope

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_merchant",
      operator: "=",
      value: @whole_foods_merchant.id
    )

    scope = condition.prepare(scope)

    filtered = condition.apply(scope)
    assert_equal 2, filtered.count
  end

  test "applies compound and condition" do
    scope = @rule_scope

    parent_condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "compound",
      operator: "and",
      sub_conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @whole_foods_merchant.id
        ),
        Rule::Condition.new(
          condition_type: "transaction_amount",
          operator: "<",
          value: "50"
        )
      ]
    )

    scope = parent_condition.prepare(scope)

    filtered = parent_condition.apply(scope)
    assert_equal 1, filtered.count
  end

  test "applies compound or condition" do
    scope = @rule_scope

    parent_condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "compound",
      operator: "or",
      sub_conditions: [
        Rule::Condition.new(
          condition_type: "transaction_merchant",
          operator: "=",
          value: @whole_foods_merchant.id
        ),
        Rule::Condition.new(
          condition_type: "transaction_amount",
          operator: "<",
          value: "50"
        )
      ]
    )

    scope = parent_condition.prepare(scope)

    filtered = parent_condition.apply(scope)
    assert_equal 2, filtered.count
  end

  test "applies transaction_category condition" do
    scope = @rule_scope

    # Set category for one transaction
    @account.transactions.first.update!(category: @grocery_category)

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_category",
      operator: "=",
      value: @grocery_category.id
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    assert_equal 1, filtered.count
    assert_equal @grocery_category.id, filtered.first.category_id
  end

  test "applies is_null condition for transaction_category" do
    scope = @rule_scope

    # Set category for one transaction
    @account.transactions.first.update!(category: @grocery_category)

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_category",
      operator: "is_null",
      value: nil
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    assert_equal 4, filtered.count
    assert filtered.all? { |t| t.category_id.nil? }
  end

  test "applies is_null condition for transaction_merchant" do
    scope = @rule_scope

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_merchant",
      operator: "is_null",
      value: nil
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    assert_equal 3, filtered.count
    assert filtered.all? { |t| t.merchant_id.nil? }
  end

  test "applies transaction_details condition with like operator" do
    scope = @rule_scope

    # Create a transaction with extra details (simulating PayPal with underlying merchant)
    paypal_entry = create_transaction(
      date: Date.current,
      account: @account,
      amount: 75,
      name: "PayPal"
    )
    paypal_entry.transaction.update!(
      extra: {
        "simplefin" => {
          "payee" => "Amazon via PayPal",
          "description" => "Purchase from Amazon",
          "memo" => "Order #12345"
        }
      }
    )

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_details",
      operator: "like",
      value: "Amazon"
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    assert_equal 1, filtered.count
    assert_equal paypal_entry.transaction.id, filtered.first.id
  end

  test "applies transaction_details condition with equal operator case-sensitive" do
    scope = @rule_scope

    # Create transaction with specific details
    transaction_entry = create_transaction(
      date: Date.current,
      account: @account,
      amount: 100,
      name: "PayPal"
    )
    transaction_entry.transaction.update!(
      extra: {
        "simplefin" => {
          "payee" => "Netflix"
        }
      }
    )

    # Test case-sensitive match (should match)
    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_details",
      operator: "=",
      value: "Netflix"
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)
    assert_equal 1, filtered.count

    # Test case-sensitive match (should NOT match due to case difference)
    condition_lowercase = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_details",
      operator: "=",
      value: "netflix"
    )

    scope = condition_lowercase.prepare(scope)
    filtered = condition_lowercase.apply(scope)
    assert_equal 0, filtered.count
  end

  test "applies transaction_details condition with is_null operator" do
    scope = @rule_scope

    # Create transaction with extra details
    transaction_with_details = create_transaction(
      date: Date.current,
      account: @account,
      amount: 50,
      name: "Transaction with details"
    )
    transaction_with_details.transaction.update!(
      extra: { "simplefin" => { "payee" => "Test Merchant" } }
    )

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_details",
      operator: "is_null",
      value: nil
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    # Should return all original transactions (which have no extra details) but not the new one
    assert_equal 5, filtered.count
    assert_not filtered.map(&:id).include?(transaction_with_details.transaction.id)
  end

  test "applies transaction_notes condition" do
    scope = @rule_scope

    # Add notes to one transaction
    transaction_entry = @account.entries.first
    transaction_entry.update!(notes: "Important: This is a business expense")

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_notes",
      operator: "like",
      value: "business expense"
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    assert_equal 1, filtered.count
    assert_equal transaction_entry.transaction.id, filtered.first.id
  end

  test "applies transaction_notes condition with is_null operator" do
    scope = @rule_scope

    # Add notes to one transaction
    transaction_entry = @account.entries.first
    transaction_entry.update!(notes: "Some notes")

    condition = Rule::Condition.new(
      rule: @transaction_rule,
      condition_type: "transaction_notes",
      operator: "is_null",
      value: nil
    )

    scope = condition.prepare(scope)
    filtered = condition.apply(scope)

    # Should return all transactions without notes
    assert_equal 4, filtered.count
    assert_not filtered.map(&:id).include?(transaction_entry.transaction.id)
  end
end
