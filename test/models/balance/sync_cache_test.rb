require "test_helper"

class Balance::SyncCacheTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(
      name: "Test Account",
      accountable: Depository.new,
      currency: "USD",
      balance: 1000
    )
  end

  test "uses custom exchange rate from transaction extra field when present" do
    # Create a transaction with EUR currency and custom exchange rate
    entry = @account.entries.create!(
      date: Date.current,
      name: "Test Transaction",
      amount: 100,  # €100
      currency: "EUR",
      entryable: Transaction.new(
        category: @family.categories.first,
        extra: { "exchange_rate" => "1.5" }  # Custom rate: 1.5 (vs actual rate might be different)
      )
    )

    sync_cache = Balance::SyncCache.new(@account)
    converted_entries = sync_cache.send(:converted_entries)

    converted_entry = converted_entries.first
    assert_equal "USD", converted_entry.currency
    assert_equal 150.0, converted_entry.amount  # 100 * 1.5 = 150
  end

  test "uses standard exchange rate lookup when custom rate not present" do
    # Create an exchange rate in the database
    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.2
    )

    entry = @account.entries.create!(
      date: Date.current,
      name: "Test Transaction",
      amount: 100,  # €100
      currency: "EUR",
      entryable: Transaction.new(
        category: @family.categories.first,
        extra: {}  # No custom exchange rate
      )
    )

    sync_cache = Balance::SyncCache.new(@account)
    converted_entries = sync_cache.send(:converted_entries)

    converted_entry = converted_entries.first
    assert_equal "USD", converted_entry.currency
    assert_equal 120.0, converted_entry.amount  # 100 * 1.2 = 120
  end

  test "handles zero custom exchange rate" do
    # Zero exchange rate should fail validation
    entry = @account.entries.build(
      date: Date.current,
      name: "Test Transaction",
      amount: 100,
      currency: "EUR",
      entryable: Transaction.new(
        category: @family.categories.first,
        extra: { "exchange_rate" => "0" }  # Edge case: zero rate
      )
    )

    assert_not entry.save
    assert entry.entryable.errors[:exchange_rate].present?
  end
end
