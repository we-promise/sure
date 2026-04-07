require "test_helper"

class Transaction::Grouper::ByMerchantOrNameTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    # Clear existing entries for isolation
    @family.accounts.each { |a| a.entries.delete_all }
  end

  test "groups uncategorized transactions by merchant name when merchant present" do
    merchant = merchants(:netflix)
    create_transaction(account: @account, name: "NETFLIX.COM", merchant: merchant)
    create_transaction(account: @account, name: "Netflix Monthly", merchant: merchant)

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal 1, groups.size
    assert_equal "Netflix", groups.first.grouping_key
    assert_equal 2, groups.first.entries.size
  end

  test "falls back to entry name when no merchant" do
    create_transaction(account: @account, name: "AMZN MKTP US")
    create_transaction(account: @account, name: "AMZN MKTP US")

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal 1, groups.size
    assert_equal "AMZN MKTP US", groups.first.grouping_key
    assert_equal 2, groups.first.entries.size
  end

  test "creates separate groups for different names" do
    create_transaction(account: @account, name: "Starbucks")
    create_transaction(account: @account, name: "Netflix")

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal 2, groups.size
  end

  test "creates separate groups for same name with different types" do
    create_transaction(account: @account, name: "Refund", amount: 50)   # expense
    create_transaction(account: @account, name: "Refund", amount: -50)  # income

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal 2, groups.size
    types = groups.map(&:transaction_type).sort
    assert_equal %w[expense income], types
  end

  test "sets transaction_type to income for negative amounts" do
    create_transaction(account: @account, name: "Paycheck", amount: -1000)

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal "income", groups.first.transaction_type
  end

  test "sets transaction_type to expense for positive amounts" do
    create_transaction(account: @account, name: "Coffee", amount: 5)

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal "expense", groups.first.transaction_type
  end

  test "excludes transfer kinds" do
    create_transaction(account: @account, name: "CC Payment", kind: "cc_payment")
    create_transaction(account: @account, name: "Funds Move", kind: "funds_movement")
    create_transaction(account: @account, name: "Regular")

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal 1, groups.size
    assert_equal "Regular", groups.first.grouping_key
  end

  test "excludes already-categorized transactions" do
    create_transaction(account: @account, name: "Categorized", category: categories(:food_and_drink))
    create_transaction(account: @account, name: "Uncategorized")

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal 1, groups.size
    assert_equal "Uncategorized", groups.first.grouping_key
  end

  test "excludes excluded entries" do
    entry = create_transaction(account: @account, name: "Excluded")
    entry.update!(excluded: true)
    create_transaction(account: @account, name: "Visible")

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal 1, groups.size
    assert_equal "Visible", groups.first.grouping_key
  end

  test "returns empty array when all transactions are categorized" do
    create_transaction(account: @account, name: "Coffee", category: categories(:food_and_drink))

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_empty groups
  end

  test "sorts groups by count descending then name ascending" do
    3.times { create_transaction(account: @account, name: "Starbucks") }
    create_transaction(account: @account, name: "Netflix")

    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries)

    assert_equal "Starbucks", groups.first.grouping_key
    assert_equal "Netflix", groups.last.grouping_key
  end

  test "respects limit and offset" do
    create_transaction(account: @account, name: "A")
    create_transaction(account: @account, name: "B")
    create_transaction(account: @account, name: "C")

    # limit
    groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries, limit: 2)
    assert_equal 2, groups.size

    # all groups
    all_groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries, limit: 10)
    assert_equal 3, all_groups.size

    # offset skips leading groups
    offset_groups = Transaction::Grouper::ByMerchantOrName.call(@family.entries, limit: 10, offset: 1)
    assert_equal 2, offset_groups.size
    assert_not_includes offset_groups.map(&:grouping_key), all_groups.first.grouping_key
  end
end
