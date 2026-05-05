require "test_helper"

class Balance::SyncCacheTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(
      name: "Test Account",
      accountable: Investment.new,
      currency: "USD",
      balance: 1000
    )
  end

  test "uses custom exchange rate from transaction extra field when present" do
    # Create a transaction with EUR currency and custom exchange rate
    _entry = @account.entries.create!(
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

    _entry = @account.entries.create!(
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

  test "converts multiple entries with correct rates" do
    # Create exchange rates
    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.2
    )
    ExchangeRate.create!(
      from_currency: "GBP",
      to_currency: "USD",
      date: Date.current,
      rate: 1.27
    )

    # Create multiple entries in different currencies
    _eur_entry = @account.entries.create!(
      date: Date.current,
      name: "EUR Transaction",
      amount: 100,
      currency: "EUR",
      entryable: Transaction.new(
        category: @family.categories.first,
        extra: {}
      )
    )

    _gbp_entry = @account.entries.create!(
      date: Date.current,
      name: "GBP Transaction",
      amount: 50,
      currency: "GBP",
      entryable: Transaction.new(
        category: @family.categories.first,
        extra: {}
      )
    )

    _usd_entry = @account.entries.create!(
      date: Date.current,
      name: "USD Transaction",
      amount: 75,
      currency: "USD",
      entryable: Transaction.new(
        category: @family.categories.first,
        extra: {}
      )
    )

    sync_cache = Balance::SyncCache.new(@account)
    converted_entries = sync_cache.send(:converted_entries)

    assert_equal 3, converted_entries.length

    # All should be in USD
    converted_entries.each { |e| assert_equal "USD", e.currency }

    # Check converted amounts
    # Sort amounts to check regardless of order
    amounts = converted_entries.map(&:amount).sort
    assert_in_delta 63.5, amounts[0], 0.01   # 50 GBP * 1.27
    assert_in_delta 75.0, amounts[1], 0.01   # 75 USD * 1.0
    assert_in_delta 120.0, amounts[2], 0.01  # 100 EUR * 1.2
  end

  # get_holdings_value

  test "returns 0 for date with no holdings" do
    cache = Balance::SyncCache.new(@account)
    assert_equal 0, cache.get_holdings_value(Date.current)
  end

  test "sums holdings value for a single date" do
    security = Security.create!(ticker: "TST", name: "Test")

    @account.holdings.create!(security: security, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD")
    @account.holdings.create!(security: security, date: 1.day.ago.to_date, qty: 10, price: 90, amount: 900, currency: "USD")

    cache = Balance::SyncCache.new(@account)
    assert_equal 1000, cache.get_holdings_value(Date.current)
    assert_equal 900, cache.get_holdings_value(1.day.ago.to_date)
  end

  test "sums multiple holdings on the same date" do
    s1 = Security.create!(ticker: "S1", name: "Security 1")
    s2 = Security.create!(ticker: "S2", name: "Security 2")

    @account.holdings.create!(security: s1, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD")
    @account.holdings.create!(security: s2, date: Date.current, qty: 5, price: 200, amount: 1000, currency: "USD")

    assert_equal 2000, Balance::SyncCache.new(@account).get_holdings_value(Date.current)
  end

  test "converts foreign currency holdings to account currency" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.5)

    security = Security.create!(ticker: "TST", name: "Test")
    @account.holdings.create!(security: security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "EUR")

    assert_equal 150.0, Balance::SyncCache.new(@account).get_holdings_value(Date.current)
  end

  test "falls back to 1:1 conversion rate when exchange rate is missing for a foreign currency holding" do
    security = Security.create!(ticker: "TST", name: "Test")
    @account.holdings.create!(security: security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "EUR")

    assert_equal 100, Balance::SyncCache.new(@account).get_holdings_value(Date.current)
  end

  test "prioritizes custom rate over fetched rate" do
    # Create fetched rate
    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.2
    )

    # Create entry with custom rate that differs from fetched
    _entry = @account.entries.create!(
      date: Date.current,
      name: "EUR Transaction with custom rate",
      amount: 100,
      currency: "EUR",
      entryable: Transaction.new(
        category: @family.categories.first,
        extra: { "exchange_rate" => "1.5" }
      )
    )

    sync_cache = Balance::SyncCache.new(@account)
    converted_entries = sync_cache.send(:converted_entries)

    converted_entry = converted_entries.first
    # Should use custom rate (1.5), not fetched rate (1.2)
    assert_equal 150.0, converted_entry.amount  # 100 * 1.5, not 100 * 1.2
  end
end
