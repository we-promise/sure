require "test_helper"

class Balance::ChartSeriesBuilderTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
  end

  test "balance series with fallbacks and gapfills" do
    account = accounts(:depository)
    account.balances.destroy_all

    # With gaps
    create_balance(account: account, date: 3.days.ago.to_date, balance: 1000)
    create_balance(account: account, date: 1.day.ago.to_date, balance: 1100)
    create_balance(account: account, date: Date.current, balance: 1200)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.last_30_days,
      interval: "1 day"
    )

    assert_equal 31, builder.balance_series.size # Last 30 days == 31 total balances
    assert_equal 0, builder.balance_series.first.value

    expected = [
      0, # No value, so fallback to 0
      1000,
      1000, # Last observation carried forward
      1100,
      1200
    ]

    assert_equal expected, builder.balance_series.last(5).map { |v| v.value.amount }
  end

  test "exchange rates apply locf when missing" do
    account = accounts(:depository)
    account.balances.destroy_all

    create_balance(account: account, date: 2.days.ago.to_date, balance: 1000)
    create_balance(account: account, date: 1.day.ago.to_date, balance: 1100)
    create_balance(account: account, date: Date.current, balance: 1200)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "EUR", # Will need to convert existing balances to EUR
      period: Period.custom(start_date: 2.days.ago.to_date, end_date: Date.current),
      interval: "1 day"
    )

    # Only 1 rate in DB. We'll be missing the first and last days in the series.
    # This rate should be applied to all days: LOCF for future dates, nearest future rate for earlier dates.
    ExchangeRate.create!(date: 1.day.ago.to_date, from_currency: "USD", to_currency: "EUR", rate: 2)

    expected = [
      2000, # No prior rate, so use nearest future rate (2:1 from 1 day ago): 1000 * 2 = 2000
      2200, # Rate available, so use 2:1 conversion (1100 USD = 2200 EUR)
      2400 # Rate NOT available, but LOCF will use the last available rate, so use 2:1 conversion (1200 USD = 2400 EUR)
    ]

    assert_equal expected, builder.balance_series.map { |v| v.value.amount }
  end

  test "combines asset and liability accounts properly" do
    asset_account = accounts(:depository)
    liability_account = accounts(:credit_card)

    Balance.destroy_all

    create_balance(account: asset_account, date: 3.days.ago.to_date, balance: 500)
    create_balance(account: asset_account, date: 1.day.ago.to_date, balance: 1000)
    create_balance(account: asset_account, date: Date.current, balance: 1000)

    create_balance(account: liability_account, date: 3.days.ago.to_date, balance: 200)
    create_balance(account: liability_account, date: 2.days.ago.to_date, balance: 200)
    create_balance(account: liability_account, date: Date.current, balance: 100)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ asset_account.id, liability_account.id ],
      currency: "USD",
      period: Period.custom(start_date: 4.days.ago.to_date, end_date: Date.current),
      interval: "1 day"
    )

    expected = [
      0, # No asset or liability balances - 4 days ago
      300, # 500 - 200 = 300 - 3 days ago
      300, # 500 - 200 = 300 (500 is locf) - 2 days ago
      800, # 1000 - 200 = 800 (200 is locf) - 1 day ago
      900 # 1000 - 100 = 900 - today
    ]

    assert_equal expected, builder.balance_series.map { |v| v.value.amount }
  end

  test "when favorable direction is down balance signage inverts" do
    account = accounts(:credit_card)
    account.balances.destroy_all

    create_balance(account: account, date: 1.day.ago.to_date, balance: 1000)
    create_balance(account: account, date: Date.current, balance: 500)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.custom(start_date: 1.day.ago.to_date, end_date: Date.current),
      favorable_direction: "up"
    )

    # Since favorable direction is up and balances are liabilities, the values should be negative
    expected = [ -1000, -500 ]

    assert_equal expected, builder.balance_series.map { |v| v.value.amount }

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.custom(start_date: 1.day.ago.to_date, end_date: Date.current),
      favorable_direction: "down"
    )

    # Since favorable direction is down and balances are liabilities, the values should be positive
    expected = [ 1000, 500 ]

    assert_equal expected, builder.balance_series.map { |v| v.value.amount }
  end

  test "uses balances matching account currency for correct chart data" do
    # This test verifies that chart data is built from balances with proper currency.
    # Data integrity is maintained by:
    # 1. Account.create_and_sync with skip_initial_sync: true for linked accounts
    # 2. Migration cleanup_orphaned_currency_balances for existing data
    account = accounts(:depository)
    account.balances.destroy_all

    # Account is in USD, create balances in USD
    create_balance(account: account, date: 2.days.ago.to_date, balance: 1000)
    create_balance(account: account, date: 1.day.ago.to_date, balance: 1500)
    create_balance(account: account, date: Date.current, balance: 2000)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.custom(start_date: 2.days.ago.to_date, end_date: Date.current),
      interval: "1 day"
    )

    series = builder.balance_series
    assert_equal 3, series.size
    assert_equal [ 1000, 1500, 2000 ], series.map { |v| v.value.amount }
  end

  test "balances are converted to target currency using exchange rates" do
    # Create account with EUR currency
    family = families(:dylan_family)
    account = family.accounts.create!(
      name: "EUR Account",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )

    account.balances.destroy_all

    # Create balances in EUR (matching account currency)
    create_balance(account: account, date: 1.day.ago.to_date, balance: 1000)
    create_balance(account: account, date: Date.current, balance: 1200)

    # Add exchange rate EUR -> USD
    ExchangeRate.create!(date: 1.day.ago.to_date, from_currency: "EUR", to_currency: "USD", rate: 1.1)

    # Request chart in USD (different from account's EUR)
    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.custom(start_date: 1.day.ago.to_date, end_date: Date.current),
      interval: "1 day"
    )

    series = builder.balance_series
    # EUR balances converted to USD at 1.1 rate (LOCF for today)
    assert_equal [ 1100, 1320 ], series.map { |v| v.value.amount }
  end

  test "linked account with orphaned currency balances shows correct values after cleanup" do
    # This test reproduces the original bug scenario:
    # 1. Linked account created with initial sync before correct currency was known
    # 2. Opening anchor and first sync created balances with wrong currency (USD)
    # 3. Provider sync updated account to correct currency (EUR) and created new balances
    # 4. Both USD and EUR balances existed - charts showed wrong values
    #
    # The fix:
    # 1. skip_initial_sync prevents this going forward
    # 2. Migration cleans up orphaned balances for existing linked accounts

    # Use the connected (linked) account fixture
    linked_account = accounts(:connected)
    linked_account.balances.destroy_all

    # Simulate the bug: account is now EUR but has old USD balances from initial sync
    linked_account.update!(currency: "EUR")

    # Create orphaned balances in wrong currency (USD) - from initial sync before currency was known
    Balance.create!(
      account: linked_account,
      date: 3.days.ago.to_date,
      balance: 1000,
      cash_balance: 1000,
      currency: "USD", # Wrong currency!
      start_cash_balance: 1000,
      start_non_cash_balance: 0,
      cash_inflows: 0,
      cash_outflows: 0,
      non_cash_inflows: 0,
      non_cash_outflows: 0,
      net_market_flows: 0,
      cash_adjustments: 0,
      non_cash_adjustments: 0,
      flows_factor: 1
    )

    Balance.create!(
      account: linked_account,
      date: 2.days.ago.to_date,
      balance: 1100,
      cash_balance: 1100,
      currency: "USD", # Wrong currency!
      start_cash_balance: 1100,
      start_non_cash_balance: 0,
      cash_inflows: 0,
      cash_outflows: 0,
      non_cash_inflows: 0,
      non_cash_outflows: 0,
      net_market_flows: 0,
      cash_adjustments: 0,
      non_cash_adjustments: 0,
      flows_factor: 1
    )

    # Create correct balances in EUR - from provider sync after currency was known
    create_balance(account: linked_account, date: 1.day.ago.to_date, balance: 5000)
    create_balance(account: linked_account, date: Date.current, balance: 5500)

    # Verify we have both currency balances (the bug state)
    assert_equal 2, linked_account.balances.where(currency: "USD").count
    assert_equal 2, linked_account.balances.where(currency: "EUR").count

    # Simulate migration cleanup: delete orphaned balances with wrong currency
    linked_account.balances.where.not(currency: linked_account.currency).delete_all

    # Verify cleanup removed orphaned balances
    assert_equal 0, linked_account.balances.where(currency: "USD").count
    assert_equal 2, linked_account.balances.where(currency: "EUR").count

    # Now chart should show correct EUR values
    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ linked_account.id ],
      currency: "EUR",
      period: Period.custom(start_date: 2.days.ago.to_date, end_date: Date.current),
      interval: "1 day"
    )

    series = builder.balance_series
    # After cleanup: only EUR balances exist, chart shows correct values
    # Day 2 ago: 0 (no EUR balance), Day 1 ago: 5000, Today: 5500
    assert_equal [ 0, 5000, 5500 ], series.map { |v| v.value.amount }
  end

  test "chart ignores orphaned currency balances via currency filter" do
    # This test verifies the currency filter correctly ignores orphaned balances.
    # The filter `b.currency = accounts.currency` ensures only valid balances are used.
    #
    # Bug scenario: Account currency changed from USD to EUR after initial sync,
    # leaving orphaned USD balances. Without the filter, charts would show wrong values.

    linked_account = accounts(:connected)
    linked_account.balances.destroy_all

    # Account is EUR but has orphaned USD balances (bug state)
    linked_account.update!(currency: "EUR")

    # Create orphaned USD balance (wrong currency)
    Balance.create!(
      account: linked_account,
      date: 1.day.ago.to_date,
      balance: 9999,
      cash_balance: 9999,
      currency: "USD", # Wrong currency - doesn't match account.currency (EUR)
      start_cash_balance: 9999,
      start_non_cash_balance: 0,
      cash_inflows: 0,
      cash_outflows: 0,
      non_cash_inflows: 0,
      non_cash_outflows: 0,
      net_market_flows: 0,
      cash_adjustments: 0,
      non_cash_adjustments: 0,
      flows_factor: 1
    )

    # Chart correctly ignores USD balance because account.currency is EUR
    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ linked_account.id ],
      currency: "EUR",
      period: Period.custom(start_date: 1.day.ago.to_date, end_date: Date.current),
      interval: "1 day"
    )

    series = builder.balance_series

    # Currency filter ensures orphaned USD balance (9999) is ignored
    # Chart shows zeros because no EUR balances exist
    assert_equal 2, series.size
    assert_equal [ 0, 0 ], series.map { |v| v.value.amount }

    # Verify the orphaned balance still exists in DB (migration will clean it up)
    assert_equal 1, linked_account.balances.where(currency: "USD").count
    assert_equal 0, linked_account.balances.where(currency: "EUR").count
  end
end
