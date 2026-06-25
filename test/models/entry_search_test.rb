require "test_helper"

class EntrySearchTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @other_account = accounts(:credit_card)
    @family.accounts.each { |account| account.entries.delete_all }
  end

  test "filters account-scoped entries by transaction category" do
    matching = create_transaction(account: @account, name: "Food", category: categories(:food_and_drink))
    other_category = create_transaction(account: @account, name: "Other", category: categories(:income))
    other_account = create_transaction(account: @other_account, name: "Other account food", category: categories(:food_and_drink))
    create_valuation(account: @account, name: "Balance")

    results = @account.entries.search(categories: [ "Food & Drink" ])

    assert_includes results, matching
    assert_not_includes results, other_category
    assert_not_includes results, other_account
  end

  test "filters account-scoped entries by transaction type" do
    expense = create_transaction(account: @account, name: "Expense", amount: 100, kind: "standard")
    income = create_transaction(account: @account, name: "Income", amount: -100, kind: "standard")
    transfer = create_transaction(account: @account, name: "Transfer", amount: 50, kind: "funds_movement")
    create_valuation(account: @account, name: "Balance")

    results = @account.entries.search(types: [ "expense" ])

    assert_includes results, expense
    assert_not_includes results, income
    assert_not_includes results, transfer
  end

  test "filters account-scoped entries by merchant" do
    matching = create_transaction(account: @account, name: "Netflix", merchant: merchants(:netflix))
    other_merchant = create_transaction(account: @account, name: "Amazon", merchant: merchants(:amazon))
    other_account = create_transaction(account: @other_account, name: "Other Netflix", merchant: merchants(:netflix))

    results = @account.entries.search(merchants: [ "Netflix" ])

    assert_includes results, matching
    assert_not_includes results, other_merchant
    assert_not_includes results, other_account
  end

  test "filters account-scoped entries by tag without duplicating entries" do
    matching = create_transaction(account: @account, name: "Tagged", tags: [ tags(:one), tags(:two) ])
    other_tag = create_transaction(account: @account, name: "Other tag", tags: [ tags(:three) ])
    other_account = create_transaction(account: @other_account, name: "Other account tagged", tags: [ tags(:one) ])

    results = @account.entries.search(tags: [ "Trips", "Emergency fund" ])

    assert_equal [ matching.id ], results.pluck(:id)
    assert_not_includes results, other_tag
    assert_not_includes results, other_account
  end
end
