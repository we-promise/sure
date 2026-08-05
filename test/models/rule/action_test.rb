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

  # The inversion action schedules a balance resync per affected account. Stub
  # it only where it is incidental, so the surrounding tests keep exercising
  # their own real sync behavior.
  def stub_account_sync
    Account.any_instance.stubs(:sync_later)
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

  test "invert_transaction_amount swaps deposits and withdrawals once" do
    stub_account_sync
    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "invert_transaction_amount"
    )
    scope = Transaction.where(id: [ @txn1.id, @txn2.id ])

    assert_equal 2, action.apply(scope)
    assert_equal(-100, @txn1.reload.entry.amount)
    assert_equal 200, @txn2.reload.entry.amount

    assert_equal 0, action.apply(scope)
    assert_equal(-100, @txn1.reload.entry.amount)
    assert_equal 200, @txn2.reload.entry.amount
  end

  test "invert_transaction_amount corrects an amount restored by provider sync" do
    stub_account_sync
    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "invert_transaction_amount"
    )
    scope = Transaction.where(id: @txn2.id)

    assert_equal 1, action.apply(scope)
    assert_equal 200, @txn2.reload.entry.amount
    assert_equal(
      { "source_amount" => "-200.0", "corrected_amount" => "200.0" },
      @txn2.amount_inversion_state
    )

    @txn2.entry.update!(amount: -200)

    assert_equal 1, action.apply(scope)
    assert_equal 200, @txn2.reload.entry.amount
    assert_equal 0, action.apply(scope)
  end

  test "invert_transaction_amount preserves provider metadata" do
    stub_account_sync
    @txn2.update!(extra: { "simplefin" => { "pending" => true } })
    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "invert_transaction_amount"
    )

    action.apply(Transaction.where(id: @txn2.id))

    assert_equal true, @txn2.reload.extra.dig("simplefin", "pending")
    assert_equal "200.0", @txn2.extra.dig("rules", "invert_transaction_amount", "corrected_amount")
  end

  test "invert_transaction_amount schedules one recalculation per affected account from the earliest date" do
    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "invert_transaction_amount"
    )

    Account.any_instance.expects(:sync_later).with(window_start_date: 1.day.ago.to_date).once

    assert_equal 2, action.apply(Transaction.where(id: [ @txn1.id, @txn3.id ]))
  end

  test "overlapping invert actions share transaction state instead of cancelling each other" do
    stub_account_sync
    other_rule = Rule.create!(
      family: @family,
      resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "invert_transaction_amount") ]
    )
    first_action = Rule::Action.new(rule: @transaction_rule, action_type: "invert_transaction_amount")
    second_action = other_rule.actions.first
    scope = Transaction.where(id: @txn2.id)

    assert_equal 1, first_action.apply(scope)
    assert_equal 0, second_action.apply(scope)
    assert_equal 200, @txn2.reload.entry.amount

    @txn2.entry.update!(amount: -200)

    assert_equal 1, second_action.apply(scope)
    assert_equal 0, first_action.apply(scope)
    assert_equal 200, @txn2.reload.entry.amount
  end

  test "invert_transaction_amount skips transfer legs so the transfer keeps opposite amounts" do
    stub_account_sync
    other_account = @family.accounts.create!(name: "Transfer target", balance: 1000, currency: "USD", accountable: Depository.new)
    outflow = create_transaction(date: Date.current, account: @account, amount: 500, name: "Transfer out").transaction
    inflow = create_transaction(date: Date.current, account: other_account, amount: -500, name: "Transfer in").transaction
    transfer = Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")

    action = Rule::Action.new(rule: @transaction_rule, action_type: "invert_transaction_amount")

    assert_equal 0, action.apply(Transaction.where(id: [ inflow.id, outflow.id ]))
    assert_equal 500, outflow.reload.entry.amount
    assert_equal(-500, inflow.reload.entry.amount)
    assert transfer.reload.valid?, "transfer must remain valid: #{transfer.errors.full_messages.inspect}"

    # An explicit re-apply must not be an escape hatch around the invariant.
    assert_equal 0, action.apply(Transaction.where(id: [ inflow.id, outflow.id ]), ignore_attribute_locks: true)
    assert_equal 500, outflow.reload.entry.amount
  end

  test "invert_transaction_amount skips split children so the split still sums to its parent" do
    stub_account_sync
    parent_entry = create_transaction(date: Date.current, account: @account, amount: 300, name: "Split parent")
    parent_entry.split!([
      { amount: 100, name: "Split child A" },
      { amount: 200, name: "Split child B" }
    ])
    child_ids = parent_entry.reload.child_entries.map(&:entryable_id)

    action = Rule::Action.new(rule: @transaction_rule, action_type: "invert_transaction_amount")

    assert_equal 0, action.apply(Transaction.where(id: child_ids))

    children = parent_entry.reload.child_entries
    assert_equal [ 100, 200 ], children.map(&:amount).map(&:to_i).sort
    assert_equal parent_entry.amount, children.sum(&:amount)
  end

  test "invert_transaction_amount still corrects a standalone transaction alongside skipped ones" do
    stub_account_sync
    other_account = @family.accounts.create!(name: "Transfer target 2", balance: 1000, currency: "USD", accountable: Depository.new)
    outflow = create_transaction(date: Date.current, account: @account, amount: 500, name: "Transfer out").transaction
    inflow = create_transaction(date: Date.current, account: other_account, amount: -500, name: "Transfer in").transaction
    Transfer.create!(inflow_transaction: inflow, outflow_transaction: outflow, status: "confirmed")

    action = Rule::Action.new(rule: @transaction_rule, action_type: "invert_transaction_amount")

    assert_equal 1, action.apply(Transaction.where(id: [ @txn2.id, inflow.id, outflow.id ]))
    assert_equal 200, @txn2.reload.entry.amount
    assert_equal 500, outflow.reload.entry.amount
  end

  test "invert_transaction_amount respects amount locks unless explicitly reapplied" do
    stub_account_sync
    @txn1.entry.lock_attr!(:amount)
    action = Rule::Action.new(
      rule: @transaction_rule,
      action_type: "invert_transaction_amount"
    )
    scope = Transaction.where(id: @txn1.id)

    assert_equal 0, action.apply(scope)
    assert_equal 100, @txn1.reload.entry.amount

    assert_equal 1, action.apply(scope, ignore_attribute_locks: true)
    assert_equal(-100, @txn1.reload.entry.amount)
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
