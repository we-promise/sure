require "test_helper"

class RuleTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)
    @whole_foods_merchant = @family.merchants.create!(name: "Whole Foods", type: "FamilyMerchant")
    @groceries_category = @family.categories.create!(name: "Groceries")
  end

  test "basic rule" do
    transaction_entry = create_transaction(date: Date.current, account: @account, merchant: @whole_foods_merchant)

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id) ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    rule.apply

    transaction_entry.reload

    assert_equal @groceries_category, transaction_entry.transaction.category
  end

  test "compound rule" do
    transaction_entry1 = create_transaction(date: Date.current, amount: 50, account: @account, merchant: @whole_foods_merchant)
    transaction_entry2 = create_transaction(date: Date.current, amount: 100, account: @account, merchant: @whole_foods_merchant)

    # Assign "Groceries" to transactions with a merchant of "Whole Foods" and an amount greater than $60
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and", sub_conditions: [
          Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id),
          Rule::Condition.new(condition_type: "transaction_amount", operator: ">", value: 60)
        ])
      ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    rule.apply

    transaction_entry1.reload
    transaction_entry2.reload

    assert_nil transaction_entry1.transaction.category
    assert_equal @groceries_category, transaction_entry2.transaction.category
  end

  test "exclude transaction rule" do
    transaction_entry = create_transaction(date: Date.current, account: @account, merchant: @whole_foods_merchant)

    assert_not transaction_entry.excluded, "Transaction should not be excluded initially"

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id) ],
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    rule.apply

    transaction_entry.reload

    assert transaction_entry.excluded, "Transaction should be excluded after rule applies"
  end

  test "exclude transaction rule respects attribute locks" do
    transaction_entry = create_transaction(date: Date.current, account: @account, merchant: @whole_foods_merchant)
    transaction_entry.lock_attr!(:excluded)

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_merchant", operator: "=", value: @whole_foods_merchant.id) ],
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    rule.apply

    transaction_entry.reload

    assert_not transaction_entry.excluded, "Transaction should not be excluded when attribute is locked"
  end

  test "transaction name rules normalize whitespace in comparisons" do
    transaction_entry = create_transaction(
      date: Date.current,
      account: @account,
      name: "Company  -   Mobile",
      amount: 80
    )

    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Company - Mobile") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    assert_equal 1, rule.affected_resource_count

    rule.apply
    transaction_entry.reload

    assert_equal @groceries_category, transaction_entry.transaction.category
  end

  # Artificial limitation put in place to prevent users from creating overly complex rules
  # Rules should be shallow and wide
  test "no nested compound conditions" do
    rule = Rule.new(
      family: @family,
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ],
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and", sub_conditions: [
          Rule::Condition.new(condition_type: "compound", operator: "and", sub_conditions: [
            Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Starbucks")
          ])
        ])
      ]
    )

    assert_not rule.valid?
    assert_equal [ "Compound conditions cannot be nested" ], rule.errors.full_messages
  end

  test "displayed_condition falls back to next valid condition when first compound condition is empty" do
    rule = Rule.new(
      family: @family,
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ],
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and"),
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "starbucks")
      ]
    )

    displayed_condition = rule.displayed_condition

    assert_not_nil displayed_condition
    assert_equal "transaction_name", displayed_condition.condition_type
    assert_equal "like", displayed_condition.operator
    assert_equal "starbucks", displayed_condition.value
  end

  test "additional_displayable_conditions_count ignores empty compound conditions" do
    rule = Rule.new(
      family: @family,
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ],
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "and"),
        Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "first"),
        Rule::Condition.new(condition_type: "transaction_amount", operator: ">", value: 100)
      ]
    )

    assert_equal 1, rule.additional_displayable_conditions_count
  end

  test "rule matching on transaction details" do
    # Create PayPal transaction with underlying merchant in details
    paypal_entry = create_transaction(
      date: Date.current,
      account: @account,
      name: "PayPal",
      amount: 50
    )
    paypal_entry.transaction.update!(
      extra: {
        "simplefin" => {
          "payee" => "Whole Foods via PayPal",
          "description" => "Grocery shopping"
        }
      }
    )

    # Create another PayPal transaction with different underlying merchant
    paypal_entry2 = create_transaction(
      date: Date.current,
      account: @account,
      name: "PayPal",
      amount: 100
    )
    paypal_entry2.transaction.update!(
      extra: {
        "simplefin" => {
          "payee" => "Amazon via PayPal"
        }
      }
    )

    # Rule to categorize PayPal transactions containing "Whole Foods" in details
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_details", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    rule.apply

    paypal_entry.reload
    paypal_entry2.reload

    assert_equal @groceries_category, paypal_entry.transaction.category, "PayPal transaction with 'Whole Foods' in details should be categorized"
    assert_nil paypal_entry2.transaction.category, "PayPal transaction without 'Whole Foods' in details should not be categorized"
  end

  test "rule matching on transaction notes" do
    # Create transaction with notes
    transaction_entry = create_transaction(
      date: Date.current,
      account: @account,
      name: "Expense",
      amount: 50
    )
    transaction_entry.update!(notes: "Business lunch with client")

    # Create another transaction without relevant notes
    transaction_entry2 = create_transaction(
      date: Date.current,
      account: @account,
      name: "Expense",
      amount: 100
    )
    transaction_entry2.update!(notes: "Personal expense")

    # Rule to categorize transactions with "business" in notes
    business_category = @family.categories.create!(name: "Business")
    rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_notes", operator: "like", value: "business") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: business_category.id) ]
    )

    rule.apply

    transaction_entry.reload
    transaction_entry2.reload

    assert_equal business_category, transaction_entry.transaction.category, "Transaction with 'business' in notes should be categorized"
    assert_nil transaction_entry2.transaction.category, "Transaction without 'business' in notes should not be categorized"
  end

  test "total_affected_resource_count deduplicates overlapping rules" do
    # Create transactions
    transaction_entry1 = create_transaction(date: Date.current, account: @account, name: "Whole Foods", amount: 50)
    transaction_entry2 = create_transaction(date: Date.current, account: @account, name: "Whole Foods", amount: 100)
    transaction_entry3 = create_transaction(date: Date.current, account: @account, name: "Target", amount: 75)

    # Rule 1: Match transactions with name "Whole Foods" (matches txn 1 and 2)
    rule1 = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "Whole Foods") ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    # Rule 2: Match transactions with amount > 60 (matches txn 2 and 3)
    rule2 = Rule.create!(
      family: @family,
      resource_type: "transaction",
      effective_date: 1.day.ago.to_date,
      conditions: [ Rule::Condition.new(condition_type: "transaction_amount", operator: ">", value: 60) ],
      actions: [ Rule::Action.new(action_type: "set_transaction_category", value: @groceries_category.id) ]
    )

    # Rule 1 affects 2 transactions, Rule 2 affects 2 transactions
    # But transaction_entry2 is matched by both, so total unique should be 3
    assert_equal 2, rule1.affected_resource_count
    assert_equal 2, rule2.affected_resource_count
    assert_equal 3, Rule.total_affected_resource_count([ rule1, rule2 ])
  end

  test "total_affected_resource_count returns zero for empty rules" do
    assert_equal 0, Rule.total_affected_resource_count([])
  end
end
