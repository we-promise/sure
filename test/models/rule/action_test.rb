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
end
