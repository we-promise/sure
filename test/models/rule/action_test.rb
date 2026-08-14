require "test_helper"

class Rule::ActionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @transaction_rule = rules(:one)
    @account = @family.accounts.create!(name: "Rule test", balance: 1000, currency: "USD", accountable: Depository.new)

    @grocery_category = @family.categories.create!(name: "Grocery")
    @whole_foods_merchant = @family.merchants.create!(name: "Whole Foods", type: "FamilyMerchant")

    # Some sample transactions to work with
    @txn1 = create_transaction(date: Date.current, account: @account, amount: 100, name: "Rule test transaction1", merchant: @whole_foods_merchant).transaction
    @txn2 = create_transaction(date: Date.current, account: @account, amount: -200, name: "Rule test transaction2").transaction
    @txn3 = create_transaction(date: 1.day.ago.to_date, account: @account, amount: 50, name: "Rule test transaction3").transaction

    @rule_scope = @account.transactions
  end

  test "set_transaction_category" do
    # Does not modify transactions that are locked (user edited them)
    @txn1.lock_attr!(:category_id)

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "set_transaction_category",
      value: @grocery_category.id
    )

    action.apply(@rule_scope)

    assert_nil @txn1.reload.category

    [ @txn2, @txn3 ].each do |transaction|
      assert_equal @grocery_category.id, transaction.reload.category_id
    end
  end

  test "set_transaction_category overrides locked category when ignore_attribute_locks" do
    # Explicit "Re-apply" from the rules UI passes ignore_attribute_locks: true (issue #2051)
    @txn1.lock_attr!(:category_id)

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "set_transaction_category",
      value: @grocery_category.id
    )

    action.apply(@rule_scope, ignore_attribute_locks: true)

    assert_equal @grocery_category.id, @txn1.reload.category_id
  end

  test "set_transaction_tags" do
    tag = @family.tags.create!(name: "Rule test tag")

    # Does not modify transactions that are locked (user edited them)
    @txn1.lock_attr!(:tag_ids)

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "set_transaction_tags",
      value: tag.id
    )

    action.apply(@rule_scope)

    assert_equal [], @txn1.reload.tags

    [ @txn2, @txn3 ].each do |transaction|
      assert_equal [ tag ], transaction.reload.tags
    end
  end

  test "set_transaction_tags preserves existing tags" do
    existing_tag = @family.tags.create!(name: "Existing tag")
    new_tag = @family.tags.create!(name: "New tag from rule")

    # Add existing tag to transaction
    @txn2.tags << existing_tag
    @txn2.save!
    assert_equal [ existing_tag ], @txn2.reload.tags

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "set_transaction_tags",
      value: new_tag.id
    )

    action.apply(@rule_scope)

    # Transaction should have BOTH the existing tag and the new tag
    @txn2.reload
    assert_includes @txn2.tags, existing_tag
    assert_includes @txn2.tags, new_tag
    assert_equal 2, @txn2.tags.count
  end

  test "set_transaction_tags does not duplicate existing tags" do
    tag = @family.tags.create!(name: "Single tag")

    # Add tag to transaction
    @txn2.tags << tag
    @txn2.save!
    assert_equal [ tag ], @txn2.reload.tags

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "set_transaction_tags",
      value: tag.id
    )

    action.apply(@rule_scope)

    # Transaction should still have just one tag (not duplicated)
    @txn2.reload
    assert_equal [ tag ], @txn2.tags
  end

  test "set_transaction_merchant" do
    merchant = @family.merchants.create!(name: "Rule test merchant")

    # Does not modify transactions that are locked (user edited them)
    @txn1.lock_attr!(:merchant_id)

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "set_transaction_merchant",
      value: merchant.id
    )

    action.apply(@rule_scope)

    assert_not_equal merchant.id, @txn1.reload.merchant_id

    [ @txn2, @txn3 ].each do |transaction|
      assert_equal merchant.id, transaction.reload.merchant_id
    end
  end

  test "set_transaction_name" do
    new_name = "Renamed Transaction"

    # Does not modify transactions that are locked (user edited them)
    @txn1.entry.lock_attr!(:name)

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "set_transaction_name",
      value: new_name
    )

    action.apply(@rule_scope)

    assert_not_equal new_name, @txn1.reload.entry.name

    [ @txn2, @txn3 ].each do |transaction|
      assert_equal new_name, transaction.reload.entry.name
    end
  end

  test "set_transaction_name overrides locked name when ignore_attribute_locks" do
    # Explicit "Re-apply" from the rules UI passes ignore_attribute_locks: true (issue #2051)
    new_name = "Renamed Transaction"
    @txn1.entry.lock_attr!(:name)

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "set_transaction_name",
      value: new_name
    )

    action.apply(@rule_scope, ignore_attribute_locks: true)

    assert_equal new_name, @txn1.reload.entry.name
  end

  test "set_investment_activity_label" do
    # Does not modify transactions that are locked (user edited them)
    @txn1.lock_attr!(:investment_activity_label)

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "set_investment_activity_label",
      value: "Dividend"
    )

    action.apply(@rule_scope)

    assert_nil @txn1.reload.investment_activity_label

    [ @txn2, @txn3 ].each do |transaction|
      assert_equal "Dividend", transaction.reload.investment_activity_label
    end
  end

  test "set_as_transfer_or_payment assigns investment_contribution kind and category for investment destination" do
    investment = accounts(:investment)

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "set_as_transfer_or_payment",
      value: investment.id
    )

    # Only apply to txn1 (positive amount = outflow)
    action.apply(Transaction.where(id: @txn1.id))

    @txn1.reload

    transfer = Transfer.find_by(outflow_transaction_id: @txn1.id) || Transfer.find_by(inflow_transaction_id: @txn1.id)
    assert transfer.present?, "Transfer should be created"

    assert_equal "investment_contribution", transfer.outflow_transaction.kind
    assert_equal "funds_movement", transfer.inflow_transaction.kind

    category = @family.investment_contributions_category
    assert_equal category, transfer.outflow_transaction.category
  end

  test "set_investment_activity_label ignores invalid values" do
    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "set_investment_activity_label",
      value: "InvalidLabel"
    )

    result = action.apply(@rule_scope)

    assert_equal 0, result
    assert_nil @txn1.reload.investment_activity_label
  end

  test "split_transaction builds value from split_rows form fields" do
    tag = @family.tags.create!(name: "Split test tag")

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "split_transaction",
      split_rows: {
        "0" => { type: "percentage", name: "Groceries", share: "70", category_id: @grocery_category.id, merchant_id: @whole_foods_merchant.id, tag_ids: [ tag.id, "" ] },
        "1" => { type: "percentage", name: "Household", share: "30", category_id: "", merchant_id: "", tag_ids: [ "" ] }
      }
    )

    assert action.valid?, action.errors.full_messages.to_sentence

    parsed = JSON.parse(action.value)
    assert_equal [ "Groceries", "Household" ], parsed["splits"].map { |s| s["name"] }
    assert_equal [ "percentage", "percentage" ], parsed["splits"].map { |s| s["type"] }
    assert_equal @grocery_category.id, parsed["splits"].first["category_id"]
    assert_nil parsed["splits"].last["category_id"]
    assert_equal @whole_foods_merchant.id, parsed["splits"].first["merchant_id"]
    assert_nil parsed["splits"].last["merchant_id"]
    assert_equal [ tag.id ], parsed["splits"].first["tag_ids"]
    assert_equal [], parsed["splits"].last["tag_ids"]
  end

  test "split_transaction rejects malformed JSON" do
    action = Rule::Action.new(rule: @transaction_rule, action_type: "split_transaction", value: "not json")

    assert_not action.valid?
    assert_includes action.errors[:value], "must be a valid split configuration"
  end

  test "split_transaction rejects fewer than two splits" do
    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "split_transaction",
      value: { splits: [ { type: "fixed", name: "Only one", share: "10" } ] }.to_json
    )

    assert_not action.valid?
    assert_includes action.errors[:value], "must have between 2 and 20 splits"
  end

  test "split_transaction rejects an invalid split type" do
    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "split_transaction",
      value: {
        splits: [ { type: "bogus", name: "A", share: "50" }, { type: "percentage", name: "B", share: "50" } ]
      }.to_json
    )

    assert_not action.valid?
    assert_includes action.errors[:value], "split #1 type must be fixed or percentage"
  end

  test "split_transaction rejects percentages that don't add up to 100" do
    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "split_transaction",
      value: {
        splits: [ { type: "percentage", name: "A", share: "50" }, { type: "percentage", name: "B", share: "40" } ]
      }.to_json
    )

    assert_not action.valid?
    assert_includes action.errors[:value], "percentages must add up to 100 (got 90.0)"
  end

  test "split_transaction rejects a non-positive share" do
    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "split_transaction",
      value: {
        splits: [ { type: "fixed", name: "A", share: "0" }, { type: "fixed", name: "B", share: "10" } ]
      }.to_json
    )

    assert_not action.valid?
    assert_includes action.errors[:value], "split #1 share must be a positive number"
  end

  test "split_transaction rejects a category from another family" do
    other_category = families(:empty).categories.create!(name: "Foreign category")

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "split_transaction",
      value: {
        splits: [
          { type: "fixed", name: "A", share: "10", category_id: other_category.id },
          { type: "fixed", name: "B", share: "10" }
        ]
      }.to_json
    )

    assert_not action.valid?
    assert_includes action.errors[:value], "split #1 category does not belong to this family"
  end

  test "split_transaction rejects a merchant from another family" do
    other_merchant = families(:empty).merchants.create!(name: "Foreign merchant", type: "FamilyMerchant")

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "split_transaction",
      value: {
        splits: [
          { type: "fixed", name: "A", share: "10", merchant_id: other_merchant.id },
          { type: "fixed", name: "B", share: "10" }
        ]
      }.to_json
    )

    assert_not action.valid?
    assert_includes action.errors[:value], "split #1 merchant does not belong to this family"
  end

  test "split_transaction rejects a tag from another family" do
    other_tag = families(:empty).tags.create!(name: "Foreign tag")

    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "split_transaction",
      value: {
        splits: [
          { type: "fixed", name: "A", share: "10", tag_ids: [ other_tag.id ] },
          { type: "fixed", name: "B", share: "10" }
        ]
      }.to_json
    )

    assert_not action.valid?
    assert_includes action.errors[:value], "split #1 has a tag that does not belong to this family"
  end

  test "split_transaction accepts a valid percentage config" do
    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "split_transaction",
      value: {
        splits: [
          { type: "percentage", name: "Groceries", share: "70", category_id: @grocery_category.id },
          { type: "percentage", name: "Household", share: "30" }
        ]
      }.to_json
    )

    assert action.valid?
  end

  test "split_transaction with only fixed splits requires an exact amount condition on the rule" do
    rule_without_amount_condition = Rule.new(family: @family, resource_type: "transaction")

    action = Rule::Action.new(
      rule: rule_without_amount_condition,
      action_type: "split_transaction",
      value: {
        splits: [
          { type: "fixed", name: "Groceries", share: "70", category_id: @grocery_category.id },
          { type: "fixed", name: "Household", share: "30" }
        ]
      }.to_json
    )

    assert_not action.valid?
    assert_includes action.errors[:value],
      "fixed-amount splits require a rule condition that matches an exact transaction amount (e.g. Amount = 42.00), otherwise the shares can't reliably sum to every matching transaction's total"
  end

  test "split_transaction with only fixed splits is valid with an exact amount condition on the rule" do
    rule_with_amount_condition = Rule.new(
      family: @family,
      resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_amount", operator: "=", value: 100) ]
    )

    action = Rule::Action.new(
      rule: rule_with_amount_condition,
      action_type: "split_transaction",
      value: {
        splits: [
          { type: "fixed", name: "Groceries", share: "70", category_id: @grocery_category.id },
          { type: "fixed", name: "Household", share: "30" }
        ]
      }.to_json
    )

    assert action.valid?
  end

  test "split_transaction with only fixed splits requires shares to sum to the exact amount condition's value" do
    rule_with_amount_condition = Rule.new(
      family: @family,
      resource_type: "transaction",
      conditions: [ Rule::Condition.new(condition_type: "transaction_amount", operator: "=", value: 100) ]
    )

    action = Rule::Action.new(
      rule: rule_with_amount_condition,
      action_type: "split_transaction",
      value: {
        splits: [
          { type: "fixed", name: "Groceries", share: "70", category_id: @grocery_category.id },
          { type: "fixed", name: "Household", share: "20" }
        ]
      }.to_json
    )

    assert_not action.valid?
    assert_includes action.errors[:value],
      "split shares must add up to 100.0, the exact amount required by this rule's condition"
  end

  test "split_transaction with only fixed splits is not satisfied by an exact amount condition inside an OR group" do
    rule_with_or_amount_condition = Rule.new(
      family: @family,
      resource_type: "transaction",
      conditions: [
        Rule::Condition.new(condition_type: "compound", operator: "any", sub_conditions: [
          Rule::Condition.new(condition_type: "transaction_amount", operator: "=", value: 100),
          Rule::Condition.new(condition_type: "transaction_name", operator: "=", value: "Foo")
        ])
      ]
    )

    action = Rule::Action.new(
      rule: rule_with_or_amount_condition,
      action_type: "split_transaction",
      value: {
        splits: [
          { type: "fixed", name: "Groceries", share: "70", category_id: @grocery_category.id },
          { type: "fixed", name: "Household", share: "30" }
        ]
      }.to_json
    )

    assert_not action.valid?
  end

  test "split_transaction with a percentage split does not require an exact amount condition" do
    rule_without_amount_condition = Rule.new(family: @family, resource_type: "transaction")

    action = Rule::Action.new(
      rule: rule_without_amount_condition,
      action_type: "split_transaction",
      value: {
        splits: [
          { type: "fixed", name: "Fee", share: "5" },
          { type: "percentage", name: "Rest", share: "100" }
        ]
      }.to_json
    )

    assert action.valid?, action.errors.full_messages.to_sentence
  end
end
