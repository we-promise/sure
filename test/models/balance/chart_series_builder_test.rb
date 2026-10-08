require "test_helper"

class Balance::ChartSeriesBuilderTest < ActiveSupport::TestCase
  include BalanceTestHelper
  include PortfolioReturnsTestHelper

  setup do
    @day_one = Date.new(2026, 3, 2)
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

  test "account active until dates stop locf while preserving date rows" do
    account = accounts(:depository)
    account.balances.destroy_all

    period = Period.custom(start_date: 2.days.ago.to_date, end_date: Date.current)
    create_balance(account: account, date: period.start_date, balance: 1000)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      account_active_until_dates: { account.id => 1.day.ago.to_date },
      currency: "USD",
      period: period,
      interval: "1 day"
    )

    assert_equal [ 1000, 1000, 0 ], builder.balance_series.map { |v| v.value.amount }
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

  test "gains series computes unrealized gains from holdings with locf" do
    account = accounts(:investment)
    account.holdings.destroy_all
    security = securities(:aapl)

    # 10 shares with avg cost of $90/share
    create_holding(account: account, security: security, date: 3.days.ago.to_date, qty: 10, price: 100, cost_basis: 90)
    create_holding(account: account, security: security, date: 1.day.ago.to_date, qty: 10, price: 110, cost_basis: 90)
    create_holding(account: account, security: security, date: Date.current, qty: 10, price: 105, cost_basis: 90)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.custom(start_date: 4.days.ago.to_date, end_date: Date.current),
      interval: "1 day"
    )

    expected = [
      0, # No holdings yet
      100, # 1000 - 900
      100, # Last observation carried forward
      200, # 1100 - 900
      150 # 1050 - 900
    ]

    assert_equal expected, builder.gains_series.map { |v| v.value.amount }
  end

  test "gains series treats unusable cost basis as zero gain" do
    account = accounts(:investment)
    account.holdings.destroy_all

    # Unlocked zero cost basis (provider "unknown") -> no gain contribution
    create_holding(account: account, security: securities(:aapl), date: Date.current, qty: 10, price: 100, cost_basis: 0)
    # Nil cost basis -> no gain contribution
    create_holding(account: account, security: securities(:msft), date: Date.current, qty: 5, price: 50, cost_basis: nil)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.custom(start_date: Date.current, end_date: Date.current),
      interval: "1 day"
    )

    assert_equal [ 0 ], builder.gains_series.map { |v| v.value.amount }

    # Locked zero cost basis (e.g. airdrop) is trusted -> full amount is gain
    account.holdings.where(security: securities(:aapl)).update_all(cost_basis_locked: true)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.custom(start_date: Date.current, end_date: Date.current),
      interval: "1 day"
    )

    assert_equal [ 1000 ], builder.gains_series.map { |v| v.value.amount }
  end

  test "gains series converts holding gains to target currency with locf rates" do
    family = families(:dylan_family)
    account = family.accounts.create!(
      name: "EUR Investment",
      balance: 1000,
      currency: "EUR",
      accountable: Investment.new
    )
    security = securities(:aapl)

    # Gains in EUR: 100 yesterday (1000 - 900), 200 today (1100 - 900)
    create_holding(account: account, security: security, date: 1.day.ago.to_date, qty: 10, price: 100, cost_basis: 90)
    create_holding(account: account, security: security, date: Date.current, qty: 10, price: 110, cost_basis: 90)

    # Single EUR -> USD rate; LOCF applies it to today as well
    ExchangeRate.create!(date: 1.day.ago.to_date, from_currency: "EUR", to_currency: "USD", rate: 1.1)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.custom(start_date: 1.day.ago.to_date, end_date: Date.current),
      interval: "1 day"
    )

    expected = [
      110, # 100 EUR * 1.1
      220 # 200 EUR * 1.1 (rate carried forward)
    ]

    assert_equal expected, builder.gains_series.map { |v| v.value.amount }
  end

  test "gains series carries cost basis forward over gap-filled holdings" do
    account = accounts(:investment)
    account.holdings.destroy_all
    security = securities(:aapl)

    create_holding(account: account, security: security, date: 2.days.ago.to_date, qty: 10, price: 100, cost_basis: 90)
    # Gap-filled rows (weekends, price gaps) are persisted without cost_basis
    create_holding(account: account, security: security, date: 1.day.ago.to_date, qty: 10, price: 100, cost_basis: nil)
    create_holding(account: account, security: security, date: Date.current, qty: 10, price: 110, cost_basis: nil)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.custom(start_date: 2.days.ago.to_date, end_date: Date.current),
      interval: "1 day"
    )

    expected = [
      100, # 1000 - 900
      100, # basis carried forward from 2 days ago, not zeroed
      200 # 1100 - 900
    ]

    assert_equal expected, builder.gains_series.map { |v| v.value.amount }
  end

  test "gains series values carry trend vs previous point" do
    account = accounts(:investment)
    account.holdings.destroy_all
    security = securities(:aapl)

    create_holding(account: account, security: security, date: 1.day.ago.to_date, qty: 10, price: 100, cost_basis: 90)
    create_holding(account: account, security: security, date: Date.current, qty: 10, price: 110, cost_basis: 90)

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.custom(start_date: 1.day.ago.to_date, end_date: Date.current),
      interval: "1 day"
    )

    series = builder.gains_series

    # First point has no prior point, so trend is flat
    assert_equal 100, series.values.first.trend.previous.amount
    assert_equal 100, series.values.first.trend.current.amount

    assert_equal 100, series.values.last.trend.previous.amount
    assert_equal 200, series.values.last.trend.current.amount
  end

  # Net contributions. The example from the issue, a day apart rather
  # than months: opened with 10,000, 5,000 deposited, a 150 dividend, 2,000
  # withdrawn. The value line moves with the market and the dividend; the
  # contributions line moves only with money the owner put in or took out.
  test "net contributions open at the opening value and step up by a deposit on its date" do
    account = lay_contributions_example

    builder = contributions_builder(account, start_date: @day_one - 2)
    series = builder.net_contributions_series

    assert_equal builder.balance_series.values.map(&:date), series.values.map(&:date),
                 "the contributions line is sampled on the value line's own dates"
    assert_equal [ 0, 0, 10_000, 15_000, 15_000, 13_000 ], series.values.map { |v| v.value.amount }
    assert_equal [ 0, 0, 10_000, 15_400, 15_900, 14_100 ], builder.balance_series.values.map { |v| v.value.amount }
    assert_equal "USD", series.values.last.value.currency.iso_code
  end

  test "a withdrawal lowers net contributions by its amount on its date" do
    account = lay_contributions_example

    amounts = contributions_builder(account).net_contributions_series.values.map { |v| v.value.amount }

    assert_equal(-2_000, amounts[3] - amounts[2])
  end

  # The delta, not the level: on the dividend's date the value line rises by
  # the dividend and the market move, and the contributions line does not move.
  # Goal#net_contributed_for's definition (balance minus net market flows)
  # would count the dividend here, which is why it was not reused.
  test "a dividend moves the value line and leaves net contributions unchanged" do
    account = lay_contributions_example
    builder = contributions_builder(account)

    values = builder.balance_series.values.map { |v| v.value.amount }
    contributions = builder.net_contributions_series.values.map { |v| v.value.amount }

    assert_equal 500, values[2] - values[1], "the dividend day moves the value line"
    assert_equal 0, contributions[2] - contributions[1], "and leaves the contributions line where it was"
  end

  test "a fee, a buy and a sell leave net contributions unchanged" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 10_000, closing: 10_000
    fee_entry account: account, date: @day_one + 1, amount: 25
    buy_trade account: account, date: @day_one + 2, qty: 10, price: 100
    sell_trade account: account, date: @day_one + 3, qty: 5, price: 120

    amounts = contributions_builder(account).net_contributions_series.values.map { |v| v.value.amount }

    assert_equal [ 10_000, 10_000, 10_000, 10_000 ], amounts
  end

  # At account scope a transfer from the family's own current account is money
  # the owner put into this account. It is internal only to a scope holding
  # both legs, which the account chart never is.
  test "a transfer in from another account in the family counts as a contribution" do
    family = families(:empty)
    account = create_portfolio_account(family: family)
    checking = family.accounts.create!(name: "Checking", balance: 5_000, currency: "USD", accountable: Depository.new)
    lay_balance account: account, date: @day_one, opening: 10_000, closing: 10_000
    Transfer::Creator.new(
      family: family,
      source_account_id: checking.id,
      destination_account_id: account.id,
      date: @day_one + 1,
      amount: 3_000
    ).create

    amounts = contributions_builder(account).net_contributions_series.values.map { |v| v.value.amount }

    assert_equal [ 10_000, 13_000, 13_000, 13_000 ], amounts
  end

  # Inception-anchored, not period-anchored: a window that opens after the
  # deposits still starts at everything put in so far.
  test "a period that starts after the deposits still opens at the cumulative figure" do
    account = lay_contributions_example

    series = contributions_builder(account, start_date: @day_one + 2).net_contributions_series

    assert_equal [ 15_000, 13_000 ], series.values.map { |v| v.value.amount }
  end

  test "a foreign-currency deposit converts at its rate" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.1
    deposit account: account, date: @day_one + 1, amount: 1_000, currency: "EUR"

    amounts = contributions_builder(account).net_contributions_series.values.map { |v| v.value.amount }

    assert_equal 2_100, amounts[1]
  end

  # A position moved in from another broker is money the owner put in, valued
  # at the position, by the same rule the returns engine uses.
  test "a security journalled in counts at its value" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    security_journal account: account, date: @day_one + 1, qty: 10, price: 50

    amounts = contributions_builder(account).net_contributions_series.values.map { |v| v.value.amount }

    assert_equal 1_500, amounts[1]
  end

  # A linked account's line opens where its trimmed value line does: on the
  # anchor date, at that day's closing value, with only the flows after it.
  test "an anchor date opens at that day's closing value and adds only later flows" do
    account = lay_contributions_example

    builder = contributions_builder(account, start_date: @day_one + 1)
    series = builder.net_contributions_series(anchor_date: @day_one + 1)

    assert_equal [ 15_400, 15_400, 13_400 ], series.values.map { |v| v.value.amount }
  end

  test "net contributions carry a trend against the previous point" do
    account = lay_contributions_example

    values = contributions_builder(account).net_contributions_series.values

    assert_equal 10_000, values.first.trend.previous.amount, "the first point has nothing before it"
    assert_equal 10_000, values[1].trend.previous.amount
    assert_equal 15_000, values[1].trend.current.amount
  end

  # A flow the returns engine cannot value
  # counts as nothing, so the line is understated from that day. The builder
  # says so rather than hiding it.
  test "net contributions say when a flow could not be valued" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    deposit account: account, date: @day_one + 1, amount: 500
    builder = contributions_builder(account)

    refute builder.net_contributions_understated?, "every flow valued"

    deposit account: account, date: @day_one + 2, amount: 1_000, currency: "EUR" # no EUR rate at all
    unconverted = contributions_builder(account)

    assert unconverted.net_contributions_understated?, "a flow with no rate"
    assert_equal 1_500, unconverted.net_contributions_series.values.last.value.amount, "and it counts as nothing"
  end

  test "an unpriced journal makes net contributions understated" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    security_journal account: account, date: @day_one + 1, qty: 10 # no price that day

    assert contributions_builder(account).net_contributions_understated?
  end

  test "fees, interest, buys and sells leave net contributions unchanged" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 10_000, closing: 10_000
    fee_entry account: account, date: @day_one + 1, amount: 25
    income_trade account: account, date: @day_one + 1, amount: 40, label: "Interest"
    buy_trade account: account, date: @day_one + 2, qty: 10, price: 100
    sell_trade account: account, date: @day_one + 3, qty: 5, price: 120

    amounts = contributions_builder(account).net_contributions_series.values.map { |v| v.value.amount }

    assert_equal [ 10_000, 10_000, 10_000, 10_000 ], amounts
  end

  # Excluded and pending entries carry no flow for the classifier, so they
  # are not money put in.
  test "excluded and pending deposits do not count" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    deposit(account: account, date: @day_one + 1, amount: 300).update!(excluded: true)
    account.entries.create!(name: "Deposit", date: @day_one + 2, amount: -700, currency: "USD",
                            entryable: Transaction.new(kind: "standard", extra: { "simplefin" => { "pending" => true } }))

    amounts = contributions_builder(account).net_contributions_series.values.map { |v| v.value.amount }

    assert_equal [ 1_000, 1_000, 1_000, 1_000 ], amounts
  end

  # Both legs inside the scope: the money went nowhere, so a two-account
  # builder does not count it, while the destination's own chart does.
  test "a transfer between two accounts in the scope is not a contribution" do
    family = families(:empty)
    first = create_portfolio_account(family: family)
    second = create_portfolio_account(family: family)
    lay_balance account: first, date: @day_one, opening: 1_000, closing: 1_000
    lay_balance account: second, date: @day_one, opening: 0, closing: 0
    Transfer::Creator.new(
      family: family,
      source_account_id: first.id,
      destination_account_id: second.id,
      date: @day_one + 1,
      amount: 400
    ).create

    both = Balance::ChartSeriesBuilder.new(
      account_ids: [ first.id, second.id ],
      currency: "USD",
      period: Period.custom(start_date: @day_one, end_date: @day_one + 3),
      interval: "1 day"
    )

    assert_equal [ 1_000, 1_000, 1_000, 1_000 ], both.net_contributions_series.values.map { |v| v.value.amount }
    assert_equal [ 0, 400, 400, 400 ], contributions_builder(second).net_contributions_series.values.map { |v| v.value.amount }
  end

  # The opening value is the first row's start balance, before that day's
  # flows. Its close already holds a deposit made that day, so opening at the
  # close would count the deposit twice.
  test "a deposit on the first balance day is counted once" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 0, closing: 5_000, cash_flow: 5_000
    deposit account: account, date: @day_one, amount: 5_000

    amounts = contributions_builder(account).net_contributions_series.values.map { |v| v.value.amount }

    assert_equal [ 5_000, 5_000, 5_000, 5_000 ], amounts
  end

  # The previous day's rate, not the entry date's: the two differ here, so
  # reading the wrong one moves the figure.
  test "a foreign-currency deposit converts at the previous day's rate" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.1
    set_rate from: "EUR", to: "USD", date: @day_one + 1, rate: 1.2
    deposit account: account, date: @day_one + 1, amount: 1_000, currency: "EUR"

    builder = contributions_builder(account)

    assert_equal [ 1_000, 2_100, 2_100, 2_100 ], builder.net_contributions_series.values.map { |v| v.value.amount }
    refute builder.net_contributions_understated?
  end

  # Opening values convert the same way: an account in another currency
  # opens at the rate of the day before its first balance.
  test "an opening value in another currency converts at the previous day's rate" do
    account = create_portfolio_account(family: families(:empty), currency: "EUR")
    lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    set_rate from: "EUR", to: "USD", date: @day_one - 1, rate: 1.5
    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.6

    builder = Balance::ChartSeriesBuilder.new(
      account_ids: [ account.id ],
      currency: "USD",
      period: Period.custom(start_date: @day_one, end_date: @day_one + 3),
      interval: "1 day"
    )

    assert_equal 1_500, builder.net_contributions_series.values.first.value.amount
    refute builder.net_contributions_understated?
  end

  # A position moved out is taken out the same way one moved in is put in:
  # at the position's value that day.
  test "a security journalled in or out counts at its position value" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    security_journal account: account, date: @day_one + 1, qty: 10, price: 50
    security_journal account: account, date: @day_one + 2, qty: -4, price: 60, holding_qty: 6

    amounts = contributions_builder(account).net_contributions_series.values.map { |v| v.value.amount }

    assert_equal [ 1_000, 1_500, 1_260, 1_260 ], amounts
  end

  # A rate is carried to a date that has none, from the nearest earlier day,
  # so a flow on such a date is valued rather than left out.
  test "a flow with no rate on its own date is valued at the last known rate" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    deposit account: account, date: @day_one + 1, amount: 500
    set_rate from: "EUR", to: "USD", date: @day_one, rate: 1.1
    deposit account: account, date: @day_one + 2, amount: 1_000, currency: "EUR"

    builder = contributions_builder(account)

    refute builder.net_contributions_understated?
    assert_equal [ 1_000, 1_500, 2_600, 2_600 ], builder.net_contributions_series.values.map { |v| v.value.amount }
  end

  test "a flow after the sampled dates does not make the line understated" do
    account = create_portfolio_account(family: families(:empty))
    lay_balance account: account, date: @day_one, opening: 1_000, closing: 1_000
    deposit account: account, date: @day_one + 5, amount: 1_000, currency: "EUR" # no EUR rate at all

    refute contributions_builder(account).net_contributions_understated?
  end

  private
    def lay_contributions_example
      account = create_portfolio_account(family: families(:empty))

      lay_balance account: account, date: @day_one, opening: 10_000, closing: 10_000
      lay_balance account: account, date: @day_one + 1, opening: 10_000, closing: 15_400, cash_flow: 5_000, market_flow: 400
      lay_balance account: account, date: @day_one + 2, opening: 15_400, closing: 15_900, cash_flow: 150, market_flow: 350
      lay_balance account: account, date: @day_one + 3, opening: 15_900, closing: 14_100, cash_flow: -2_000, market_flow: 200

      deposit account: account, date: @day_one + 1, amount: 5_000
      income_transaction account: account, date: @day_one + 2, amount: 150
      deposit account: account, date: @day_one + 3, amount: -2_000

      account
    end

    def contributions_builder(account, start_date: @day_one)
      Balance::ChartSeriesBuilder.new(
        account_ids: [ account.id ],
        currency: account.currency,
        period: Period.custom(start_date: start_date, end_date: @day_one + 3),
        interval: "1 day"
      )
    end

    def create_holding(account:, security:, date:, qty:, price:, cost_basis:)
      Holding.create!(
        account: account,
        security: security,
        date: date,
        qty: qty,
        price: price,
        amount: qty * price,
        currency: account.currency,
        cost_basis: cost_basis
      )
    end
end
