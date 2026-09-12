require "test_helper"

class Rule::ActionExecutor::SplitTransactionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @rule = rules(:one)
    @account = @family.accounts.create!(name: "Split rule test", balance: 1000, currency: "USD", accountable: Depository.new)

    @groceries = @family.categories.create!(name: "Split Groceries")
    @household = @family.categories.create!(name: "Split Household")

    @rule_scope = @account.transactions
  end

  # `type:` sets a shared split type on every row that doesn't declare its own (most tests use
  # one type throughout); pass per-row `type:` in `splits` directly to test a mixed config.
  def build_action(splits:, type: nil)
    splits = splits.map { |split| split[:type] ? split : split.merge(type: type) } if type
    Rule::Action.new(rule: @rule, action_type: "split_transaction", value: { splits: splits }.to_json)
  end

  test "fixed split applies per-split merchant and tags" do
    merchant = @family.merchants.create!(name: "Split merchant", type: "FamilyMerchant")
    tag = @family.tags.create!(name: "Split tag")
    entry = create_transaction(amount: 100, name: "Bundle", account: @account)

    action = build_action(
      type: "fixed",
      splits: [
        { name: "Groceries", share: "70", merchant_id: merchant.id, tag_ids: [ tag.id ] },
        { name: "Household", share: "30" }
      ]
    )

    action.apply(@rule_scope)

    entry.reload
    with_merchant = entry.child_entries.find_by(amount: 70)
    without_merchant = entry.child_entries.find_by(amount: 30)

    assert_equal merchant.id, with_merchant.transaction.merchant_id
    assert_equal [ tag ], with_merchant.transaction.tags
    assert_equal [], without_merchant.transaction.tags
  end

  test "ignores a merchant and tags that don't belong to the family" do
    other_family_merchant = families(:empty).merchants.create!(name: "Foreign merchant", type: "FamilyMerchant")
    other_family_tag = families(:empty).tags.create!(name: "Foreign tag")
    entry = create_transaction(amount: 100, name: "Bundle", account: @account)

    action = build_action(
      type: "fixed",
      splits: [
        { name: "Part 1", share: "70", merchant_id: other_family_merchant.id, tag_ids: [ other_family_tag.id ] },
        { name: "Part 2", share: "30" }
      ]
    )

    action.apply(@rule_scope)

    entry.reload
    child = entry.child_entries.find_by(amount: 70)
    assert_nil child.transaction.merchant_id
    assert_equal [], child.transaction.tags
  end

  test "value_display summarizes the split configuration" do
    action = build_action(
      type: "percentage",
      splits: [ { name: "A", share: "60" }, { name: "B", share: "40" } ]
    )

    assert_equal "2 splits", action.value_display
  end

  test "fixed split creates children with correct amounts and categories" do
    entry = create_transaction(amount: 100, name: "Bundle", account: @account)

    action = build_action(
      type: "fixed",
      splits: [
        { name: "Groceries", share: "70", category_id: @groceries.id },
        { name: "Household", share: "30", category_id: @household.id }
      ]
    )

    modified = action.apply(@rule_scope)

    assert_equal 1, modified
    entry.reload
    assert entry.split_parent?
    assert entry.excluded?

    children = entry.child_entries.order(:amount)
    assert_equal [ 30, 70 ], children.map(&:amount)
    assert_equal [ @household.id, @groceries.id ], children.map { |c| c.transaction.category_id }
  end

  test "percentage split rounds correctly and sums to the exact original amount" do
    entry = create_transaction(amount: 100.01, name: "Bundle", account: @account)

    action = build_action(
      type: "percentage",
      splits: [
        { name: "Part 1", share: "33.33" },
        { name: "Part 2", share: "33.33" },
        { name: "Part 3", share: "33.34" }
      ]
    )

    action.apply(@rule_scope)

    entry.reload
    children = entry.child_entries
    assert_equal 3, children.size
    assert_equal entry.amount, children.sum(&:amount)
  end

  test "fixed split skips a transaction whose amount doesn't match the configured shares" do
    matching = create_transaction(amount: 100, name: "Bundle A", account: @account)
    mismatched = create_transaction(amount: 55, name: "Bundle B", account: @account)

    action = build_action(
      type: "fixed",
      splits: [
        { name: "Part 1", share: "70" },
        { name: "Part 2", share: "30" }
      ]
    )

    modified = action.apply(@rule_scope)

    assert_equal 1, modified
    assert matching.reload.split_parent?
    refute mismatched.reload.split_parent?
  end

  test "percentage split skips a transaction when rounding drift would create a non-positive amount" do
    entry = create_transaction(amount: 0.02, name: "Tiny bundle", account: @account)

    # A valid 100% split (unlike a mismatched total, this could actually pass save-time
    # validation): the first two shares round up to $0.01 each against a $0.02 total, leaving
    # $0.00 for the third split, which absorbs whatever's left.
    action = build_action(
      type: "percentage",
      splits: [
        { name: "Part 1", share: "33.33" },
        { name: "Part 2", share: "33.33" },
        { name: "Part 3", share: "33.34" }
      ]
    )

    modified = action.apply(@rule_scope)

    assert_equal 0, modified
    refute entry.reload.split_parent?
  end

  test "skips transactions that are not splittable" do
    transfer = create_transfer(from_account: @account, to_account: accounts(:credit_card), amount: 40)
    pending = create_transaction(amount: 40, name: "Pending", account: @account)
    pending.transaction.update!(extra: { "simplefin" => { "pending" => true } })
    excluded = create_transaction(amount: 40, name: "Excluded", account: @account, excluded: true)
    already_split = create_transaction(amount: 40, name: "Already split", account: @account)
    already_split.split!([ { name: "A", amount: 20 }, { name: "B", amount: 20 } ])

    action = build_action(
      type: "fixed",
      splits: [
        { name: "Part 1", share: "20" },
        { name: "Part 2", share: "20" }
      ]
    )

    modified = action.apply(@rule_scope)

    assert_equal 0, modified
    refute transfer.outflow_transaction.entry.reload.split_parent?
    refute pending.reload.split_parent?
    refute excluded.reload.split_parent?
    assert_equal 2, already_split.reload.child_entries.count
  end

  test "ignores a category id that doesn't belong to the family" do
    other_family_category = families(:empty).categories.create!(name: "Other family category")
    entry = create_transaction(amount: 100, name: "Bundle", account: @account)

    action = build_action(
      type: "fixed",
      splits: [
        { name: "Part 1", share: "70", category_id: other_family_category.id },
        { name: "Part 2", share: "30" }
      ]
    )

    action.apply(@rule_scope)

    entry.reload
    child = entry.child_entries.find_by(amount: 70)
    assert_nil child.transaction.category_id
  end

  test "income transactions produce negative child amounts" do
    entry = create_transaction(amount: -100, name: "Refund bundle", account: @account)

    action = build_action(
      type: "percentage",
      splits: [
        { name: "Part 1", share: "60" },
        { name: "Part 2", share: "40" }
      ]
    )

    action.apply(@rule_scope)

    entry.reload
    assert_equal [ -60, -40 ], entry.child_entries.order(amount: :asc).pluck(:amount).map(&:to_i)
    assert_equal(-100, entry.child_entries.sum(&:amount))
  end

  test "does not re-split an already-split transaction on re-apply" do
    entry = create_transaction(amount: 100, name: "Bundle", account: @account)

    action = build_action(
      type: "fixed",
      splits: [
        { name: "Part 1", share: "70" },
        { name: "Part 2", share: "30" }
      ]
    )

    action.apply(@rule_scope)
    assert_equal 2, entry.reload.child_entries.count

    second_pass = action.apply(@rule_scope)

    assert_equal 0, second_pass
    assert_equal 2, entry.reload.child_entries.count
  end

  test "mixed split takes fixed amounts off the top, then divides the remainder by percentage" do
    entry = create_transaction(amount: 100, name: "Bundle", account: @account)

    action = build_action(
      splits: [
        { type: "fixed", name: "Processing fee", share: "5", category_id: @household.id },
        { type: "percentage", name: "Groceries", share: "100", category_id: @groceries.id }
      ]
    )

    action.apply(@rule_scope)

    entry.reload
    fee = entry.child_entries.find_by(amount: 5)
    rest = entry.child_entries.find_by(amount: 95)

    assert_equal @household.id, fee.transaction.category_id
    assert_equal @groceries.id, rest.transaction.category_id
  end

  test "mixed split divides the post-fixed remainder proportionally across multiple percentage rows" do
    entry = create_transaction(amount: 110, name: "Bundle", account: @account)

    action = build_action(
      splits: [
        { type: "fixed", name: "Fee", share: "10" },
        { type: "percentage", name: "Part A", share: "60" },
        { type: "percentage", name: "Part B", share: "40" }
      ]
    )

    action.apply(@rule_scope)

    entry.reload
    children = entry.child_entries.order(:amount)
    # $100 remains after the $10 fee; 60/40 of that is $60/$40.
    assert_equal [ 10, 40, 60 ], children.map(&:amount)
  end

  test "mixed split skips a transaction where fixed amounts exceed the total, leaving nothing for percentages" do
    entry = create_transaction(amount: 10, name: "Small bundle", account: @account)

    action = build_action(
      splits: [
        { type: "fixed", name: "Fee", share: "20" },
        { type: "percentage", name: "Rest", share: "100" }
      ]
    )

    modified = action.apply(@rule_scope)

    assert_equal 0, modified
    refute entry.reload.split_parent?
  end
end
