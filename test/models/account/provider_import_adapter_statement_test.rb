require "test_helper"

# Covers the two options find_duplicate_transaction grew for statement imports:
# seeing provider-sourced entries, and tolerating a small date difference.
class Account::ProviderImportAdapterStatementTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @adapter = Account::ProviderImportAdapter.new(@account)
    @date = Date.current
  end

  test "provider-synced entries stay invisible by default" do
    create_transaction(account: @account, date: @date, amount: 50, external_id: "plaid-1", source: "plaid")

    assert_nil @adapter.find_duplicate_transaction(date: @date, amount: 50, currency: "USD")
  end

  test "provider-synced entries are found when the caller opts in" do
    synced = create_transaction(account: @account, date: @date, amount: 50, external_id: "plaid-1", source: "plaid")

    found = @adapter.find_duplicate_transaction(
      date: @date, amount: 50, currency: "USD", include_provider_entries: true
    )

    assert_equal synced, found
  end

  test "manual entries are still found when opting in" do
    manual = create_transaction(account: @account, date: @date, amount: 50)

    found = @adapter.find_duplicate_transaction(
      date: @date, amount: 50, currency: "USD", include_provider_entries: true
    )

    assert_equal manual, found
  end

  test "an exact-date search ignores neighbouring dates" do
    create_transaction(account: @account, date: @date - 2, amount: 50)

    assert_nil @adapter.find_duplicate_transaction(date: @date, amount: 50, currency: "USD")
  end

  test "a windowed search finds a nearby date" do
    nearby = create_transaction(account: @account, date: @date - 2, amount: 50)

    found = @adapter.find_duplicate_transaction(date: @date, amount: 50, currency: "USD", date_window: 3)

    assert_equal nearby, found
  end

  test "a windowed search prefers the closest date" do
    create_transaction(account: @account, date: @date - 3, amount: 50, name: "Far")
    closest = create_transaction(account: @account, date: @date + 1, amount: 50, name: "Near")

    found = @adapter.find_duplicate_transaction(date: @date, amount: 50, currency: "USD", date_window: 3)

    assert_equal closest, found
  end

  test "a windowed search still respects the window edge" do
    create_transaction(account: @account, date: @date - 5, amount: 50)

    assert_nil @adapter.find_duplicate_transaction(date: @date, amount: 50, currency: "USD", date_window: 3)
  end

  test "amount and currency still have to match exactly" do
    create_transaction(account: @account, date: @date, amount: 50)

    assert_nil @adapter.find_duplicate_transaction(date: @date, amount: 51, currency: "USD", date_window: 3)
    assert_nil @adapter.find_duplicate_transaction(date: @date, amount: 50, currency: "EUR", date_window: 3)
  end

  test "already-claimed entries are excluded" do
    first = create_transaction(account: @account, date: @date, amount: 50)
    second = create_transaction(account: @account, date: @date, amount: 50)

    found = @adapter.find_duplicate_transaction(
      date: @date, amount: 50, currency: "USD", date_window: 3, exclude_entry_ids: [ first.id ]
    )

    assert_equal second, found
  end
end
