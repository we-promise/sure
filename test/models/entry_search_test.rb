require "test_helper"

class EntrySearchTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @account.entries.delete_all
  end

  test "search filters entries by category, tag, merchant and type like Transaction::Search" do
    food = create_transaction(account: @account, amount: 100, category: categories(:food_and_drink))
    other = create_transaction(account: @account, amount: 100, category: categories(:income))

    result_ids = @account.entries.search(
      { categories: [ "Food & Drink" ] }, @family
    ).pluck(:id)

    assert_includes result_ids, food.id
    assert_not_includes result_ids, other.id
  end

  test "category filter excludes non-Transaction entries (Valuations, Trades)" do
    uncategorized_txn = create_transaction(account: @account, amount: 100)
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search(
      { categories: [ Category::UNCATEGORIZED_FILTER_VALUE ] }, @family
    ).pluck(:id)

    assert_includes result_ids, uncategorized_txn.id
    assert_not_includes result_ids, valuation.id
  end

  test "type filter excludes non-Transaction entries" do
    expense = create_transaction(account: @account, amount: 100, kind: "standard")
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search({ types: [ "expense" ] }).pluck(:id)

    assert_includes result_ids, expense.id
    assert_not_includes result_ids, valuation.id
  end

  test "type filter excludes non-Transaction entries even when every type is selected" do
    expense = create_transaction(account: @account, amount: 100, kind: "standard")
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search({ types: [ "expense", "income", "transfer" ] }).pluck(:id)

    assert_includes result_ids, expense.id
    assert_not_includes result_ids, valuation.id
  end

  test "merchant filter's No merchant bucket excludes non-Transaction entries" do
    without_merchant = create_transaction(account: @account, amount: 100)
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search(
      { merchants: [ Merchant::NO_MERCHANT_FILTER_VALUE ] }
    ).pluck(:id)

    assert_includes result_ids, without_merchant.id
    assert_not_includes result_ids, valuation.id
  end

  test "tag filter's Untagged bucket excludes non-Transaction entries" do
    without_tag = create_transaction(account: @account, amount: 100)
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search(
      { tags: [ Tag::UNTAGGED_FILTER_VALUE ] }
    ).pluck(:id)

    assert_includes result_ids, without_tag.id
    assert_not_includes result_ids, valuation.id
  end

  test "merchant filter for a real merchant name still excludes Valuations" do
    with_merchant = create_transaction(account: @account, amount: 100, merchant: merchants(:netflix))
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search(
      { merchants: [ merchants(:netflix).name ] }
    ).pluck(:id)

    assert_includes result_ids, with_merchant.id
    assert_not_includes result_ids, valuation.id
  end

  test "tag filter for a real tag name still excludes Valuations" do
    with_tag = create_transaction(account: @account, amount: 100, tags: [ tags(:one) ])
    valuation = create_valuation(account: @account)

    result_ids = @account.entries.search(
      { tags: [ tags(:one).name ] }
    ).pluck(:id)

    assert_includes result_ids, with_tag.id
    assert_not_includes result_ids, valuation.id
  end

  test "search / date / amount / status filters still apply to every entry type" do
    valuation = create_valuation(account: @account, amount: 5000)
    valuation.update!(name: "Reconciliation valuation")
    txn = create_transaction(account: @account, amount: 100, name: "Reconciliation check")

    result_ids = @account.entries.search({ search: "reconciliation" }).pluck(:id)

    assert_includes result_ids, valuation.id
    assert_includes result_ids, txn.id
  end

  test "without a transaction-specific filter, non-Transaction entries are not excluded" do
    valuation = create_valuation(account: @account)
    txn = create_transaction(account: @account, amount: 100)

    result_ids = @account.entries.search({}).pluck(:id)

    assert_includes result_ids, valuation.id
    assert_includes result_ids, txn.id
  end

  test "family is not required unless a category filter is used" do
    txn = create_transaction(account: @account, amount: 100, merchant: merchants(:netflix))

    result_ids = @account.entries.search({ merchants: [ merchants(:netflix).name ] }).pluck(:id)

    assert_includes result_ids, txn.id
  end
end
