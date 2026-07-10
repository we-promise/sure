require "test_helper"

class EntriesHelperTest < ActionView::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    Current.stubs(:family).returns(@family)

    @account = @family.accounts.create!(name: "Base currency test", balance: 1000, currency: "USD", accountable: Depository.new)
  end

  test "entry_group_base_currency_total returns nil when all entries are in the base currency" do
    entries = [
      create_transaction(date: Date.current, account: @account, amount: 100),
      create_transaction(date: Date.current, account: @account, amount: 50)
    ]

    assert_nil entry_group_base_currency_total(entries, Date.current)
  end

  test "entry_group_base_currency_total converts foreign currency entries with the cached rate" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.2, date: Date.current)

    entries = [
      create_transaction(date: Date.current, account: @account, amount: 100),
      create_transaction(date: Date.current, account: @account, amount: 50, currency: "EUR")
    ]

    total = entry_group_base_currency_total(entries, Date.current)

    assert_equal Money.new(-160, "USD"), total
  end

  test "entry_group_base_currency_total uses the nearest cached rate within the lookback window" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.5, date: 2.days.ago.to_date)

    entries = [ create_transaction(date: Date.current, account: @account, amount: 100, currency: "EUR") ]

    assert_equal Money.new(-150, "USD"), entry_group_base_currency_total(entries, Date.current)
  end

  test "entry_group_base_currency_total returns nil when a rate is not cached" do
    entries = [
      create_transaction(date: Date.current, account: @account, amount: 100),
      create_transaction(date: Date.current, account: @account, amount: 50, currency: "CAD")
    ]

    assert_nil entry_group_base_currency_total(entries, Date.current)
  end

  test "entry_group_base_currency_total excludes transfer transactions like the per-currency totals" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", rate: 1.2, date: Date.current)

    regular = create_transaction(date: Date.current, account: @account, amount: 50, currency: "EUR")
    transfer = create_transaction(date: Date.current, account: @account, amount: 500, kind: "funds_movement")

    total = entry_group_base_currency_total([ regular, transfer ], Date.current)

    assert_equal Money.new(-60, "USD"), total
  end
end
