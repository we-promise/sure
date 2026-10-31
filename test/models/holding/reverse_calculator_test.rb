require "test_helper"

class Holding::ReverseCalculatorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = families(:empty).accounts.create!(
      name: "Test",
      balance: 20000,
      cash_balance: 20000,
      currency: "USD",
      accountable: Investment.new
    )
  end

  test "no holdings" do
    empty_snapshot = OpenStruct.new(to_h: {})
    calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: empty_snapshot).calculate
    assert_equal [], calculated
  end

  test "holding generation respects user timezone and last generated date is current user date" do
    # Simulate user in EST timezone
    Time.use_zone("America/New_York") do
      # Set current time to 1am UTC on Jan 5, 2025
      # This would be 8pm EST on Jan 4, 2025 (user's time, and the last date we should generate holdings for)
      travel_to Time.utc(2025, 01, 05, 1, 0, 0)

      voo = Security.create!(ticker: "VOO", name: "Vanguard S&P 500 ETF")
      Security::Price.create!(security: voo, date: "2025-01-02", price: 500)
      Security::Price.create!(security: voo, date: "2025-01-03", price: 500)
      Security::Price.create!(security: voo, date: "2025-01-04", price: 500)

      # Today's holdings (provided)
      @account.holdings.create!(security: voo, date: "2025-01-04", qty: 10, price: 500, amount: 5000, currency: "USD")

      create_trade(voo, qty: 10, date: "2025-01-03", price: 500, account: @account)

      expected = [ [ "2025-01-02", 0 ], [ "2025-01-03", 5000 ], [ "2025-01-04", 5000 ] ]
      # Mock snapshot with the holdings we created
      snapshot = OpenStruct.new(to_h: { voo.id => 10 })
      calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate

      assert_equal expected, calculated.sort_by(&:date).map { |b| [ b.date.to_s, b.amount ] }
    end
  end

  # Should be able to handle this case, although we should not be reverse-syncing an account without provided current day holdings
  test "reverse portfolio with trades but without current day holdings" do
    voo = Security.create!(ticker: "VOO", name: "Vanguard S&P 500 ETF")
    Security::Price.create!(security: voo, date: Date.current, price: 470)
    Security::Price.create!(security: voo, date: 1.day.ago.to_date, price: 470)

    create_trade(voo, qty: -10, date: Date.current, price: 470, account: @account)

    # Mock empty portfolio since no current day holdings
    snapshot = OpenStruct.new(to_h: { voo.id => 0 })
    calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate
    assert_equal 2, calculated.length
  end

  test "reverse portfolio calculation" do
    load_today_portfolio

    # Build up to 10 shares of VOO (current value $5000)
    create_trade(@voo, qty: 20, date: 3.days.ago.to_date, price: 470, account: @account)
    create_trade(@voo, qty: -15, date: 2.days.ago.to_date, price: 480, account: @account)
    create_trade(@voo, qty: 5, date: 1.day.ago.to_date, price: 490, account: @account)

    # Amazon won't exist in current holdings because qty is zero, but should show up in historical portfolio
    create_trade(@amzn, qty: 1, date: 2.days.ago.to_date, price: 200, account: @account)
    create_trade(@amzn, qty: -1, date: 1.day.ago.to_date, price: 200, account: @account)

    # Build up to 100 shares of WMT (current value $10000)
    create_trade(@wmt, qty: 100, date: 1.day.ago.to_date, price: 100, account: @account)

    expected = [
      # 4 days ago
      Holding.new(security: @voo, date: 4.days.ago.to_date, qty: 0, price: 460, amount: 0),
      Holding.new(security: @wmt, date: 4.days.ago.to_date, qty: 0, price: 100, amount: 0),
      Holding.new(security: @amzn, date: 4.days.ago.to_date, qty: 0, price: 200, amount: 0),

      # 3 days ago
      Holding.new(security: @voo, date: 3.days.ago.to_date, qty: 20, price: 470, amount: 9400),
      Holding.new(security: @wmt, date: 3.days.ago.to_date, qty: 0, price: 100, amount: 0),
      Holding.new(security: @amzn, date: 3.days.ago.to_date, qty: 0, price: 200, amount: 0),

      # 2 days ago
      Holding.new(security: @voo, date: 2.days.ago.to_date, qty: 5, price: 480, amount: 2400),
      Holding.new(security: @wmt, date: 2.days.ago.to_date, qty: 0, price: 100, amount: 0),
      Holding.new(security: @amzn, date: 2.days.ago.to_date, qty: 1, price: 200, amount: 200),

      # 1 day ago
      Holding.new(security: @voo, date: 1.day.ago.to_date, qty: 10, price: 490, amount: 4900),
      Holding.new(security: @wmt, date: 1.day.ago.to_date, qty: 100, price: 100, amount: 10000),
      Holding.new(security: @amzn, date: 1.day.ago.to_date, qty: 0, price: 200, amount: 0),

      # Today
      Holding.new(security: @voo, date: Date.current, qty: 10, price: 500, amount: 5000),
      Holding.new(security: @wmt, date: Date.current, qty: 100, price: 100, amount: 10000),
      Holding.new(security: @amzn, date: Date.current, qty: 0, price: 200, amount: 0)
    ]

    # Mock snapshot with today's portfolio from load_today_portfolio
    snapshot = OpenStruct.new(to_h: { @voo.id => 10, @wmt.id => 100, @amzn.id => 0 })
    calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate

    assert_equal expected.length, calculated.length

    expected.each do |expected_entry|
      calculated_entry = calculated.find { |c| c.security_id == expected_entry.security_id && c.date == expected_entry.date }
      assert_not_nil calculated_entry, "No calculated entry for security_id=#{expected_entry.security_id} on #{expected_entry.date}"

      assert_equal expected_entry.qty, calculated_entry.qty, "Qty mismatch for security_id=#{expected_entry.security_id} on #{expected_entry.date}"
      assert_equal expected_entry.price, calculated_entry.price, "Price mismatch for security_id=#{expected_entry.security_id} on #{expected_entry.date}"
      assert_equal expected_entry.amount, calculated_entry.amount, "Amount mismatch for security_id=#{expected_entry.security_id} on #{expected_entry.date}"
    end
  end

  # For a reverse sync, Plaid will provide today's holdings + prices.  We need to match those exactly so balances match in net worth rollups.
  test "current day holdings always match provided holdings and prices" do
    # Provider gives us total value of $10,000 ($5,000 cash, $5,000 in holdings)
    @account.update!(balance: 10000, cash_balance: 5000)

    wmt = Security.create!(ticker: "WMT", name: "Walmart Inc.")
    create_trade(wmt, qty: 50, date: 1.day.ago.to_date, price: 98, account: @account)

    @account.holdings.create!(
      date: Date.current,
      price: 100,
      qty: 50,
      amount: 5000,
      currency: "USD",
      security: wmt
    )

    Security::Price.create!(security: wmt, date: Date.current, price: 102) # This price should be ignored on current day
    Security::Price.create!(security: wmt, date: 1.day.ago, price: 98) # This price will be used for historical holding calculation
    Security::Price.create!(security: wmt, date: 2.days.ago, price: 95) # This price will be used for historical holding calculation

    expected = [
      Holding.new(security: wmt, date: 2.days.ago.to_date, qty: 0, price: 95, amount: 0), # Uses market price, empty holding
      Holding.new(security: wmt, date: 1.day.ago.to_date, qty: 50, price: 98, amount: 4900), # Uses market price
      Holding.new(security: wmt, date: Date.current, qty: 50, price: 100, amount: 5000) # Uses holding price, not market price
    ]

    # Mock snapshot with WMT holding from the test setup
    snapshot = OpenStruct.new(to_h: { wmt.id => 50 })
    calculated = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate

    assert_equal expected.length, calculated.length

    expected.each do |expected_entry|
      calculated_entry = calculated.find { |c| c.security_id == expected_entry.security_id && c.date == expected_entry.date }
      assert_not_nil calculated_entry, "No calculated entry for security_id=#{expected_entry.security_id} on #{expected_entry.date}"

      assert_equal expected_entry.qty, calculated_entry.qty, "Qty mismatch for security_id=#{expected_entry.security_id} on #{expected_entry.date}"
      assert_equal expected_entry.price, calculated_entry.price, "Price mismatch for security_id=#{expected_entry.security_id} on #{expected_entry.date}"
      assert_equal expected_entry.amount, calculated_entry.amount, "Amount mismatch for security_id=#{expected_entry.security_id} on #{expected_entry.date}"
    end
  end

  # cost_basis_for

  test "cost_basis_for returns nil when there are no buy trades" do
    security = Security.create!(ticker: "TST", name: "Test")
    calc = calculator_with_trades(security)

    assert_nil cost_basis_for(calc, security, Date.current)
  end

  test "cost_basis_for returns nil for dates before the first buy" do
    security = Security.create!(ticker: "TST", name: "Test")
    buy_date = 5.days.ago.to_date

    calc = calculator_with_trades(security) do
      create_trade(security, account: @account, qty: 10, price: 100, date: buy_date)
    end

    assert_nil cost_basis_for(calc, security, buy_date - 1)
  end

  test "cost_basis_for returns weighted average cost on buy date" do
    security = Security.create!(ticker: "TST", name: "Test")
    buy_date = 5.days.ago.to_date

    calc = calculator_with_trades(security) do
      create_trade(security, account: @account, qty: 10, price: 100, date: buy_date)
    end

    assert_in_delta 100.0, cost_basis_for(calc, security, buy_date).to_f, 1e-6
  end

  # An acquisition fee is part of what the units cost, so it belongs in the
  # basis. Providers already record it on the trade; nothing used to read it.
  test "cost_basis_for includes the fee charged on an acquisition" do
    security = Security.create!(ticker: "TST", name: "Test")
    buy_date = 5.days.ago.to_date

    calc = calculator_with_trades(security) do
      create_trade(security, account: @account, qty: 10, price: 100, fee: 25, date: buy_date)
    end

    # 10 * 100 + 25 = 1,025 for 10 units
    assert_in_delta 102.5, cost_basis_for(calc, security, buy_date).to_f, 1e-6
  end

  test "cost_basis_for carries forward to dates between buys" do
    security = Security.create!(ticker: "TST", name: "Test")
    first_buy  = 10.days.ago.to_date
    second_buy = 3.days.ago.to_date

    calc = calculator_with_trades(security) do
      create_trade(security, account: @account, qty: 10, price: 100, date: first_buy)
      create_trade(security, account: @account, qty: 5,  price: 130, date: second_buy)
    end

    # Between the two buys, cost basis is from the first buy only
    assert_in_delta 100.0, cost_basis_for(calc, security, first_buy + 1).to_f, 1e-6
    assert_in_delta 100.0, cost_basis_for(calc, security, second_buy - 1).to_f, 1e-6

    # After second buy: WAC = (10*100 + 5*130) / 15 = 110.0
    assert_in_delta 110.0, cost_basis_for(calc, security, second_buy).to_f, 1e-6
    assert_in_delta 110.0, cost_basis_for(calc, security, Date.current).to_f, 1e-6
  end

  test "cost_basis_for accumulates multiple buys on the same date" do
    security = Security.create!(ticker: "TST", name: "Test")
    buy_date = 5.days.ago.to_date

    calc = calculator_with_trades(security) do
      create_trade(security, account: @account, qty: 10, price: 100, date: buy_date)
      create_trade(security, account: @account, qty: 5,  price: 130, date: buy_date)
    end

    # WAC = (10*100 + 5*130) / 15 = 110.0 — not the intermediate value after only the first trade
    assert_in_delta 110.0, cost_basis_for(calc, security, buy_date).to_f, 1e-6
  end

  test "cost_basis_for ignores sell trades" do
    security = Security.create!(ticker: "TST", name: "Test")
    buy_date  = 10.days.ago.to_date
    sell_date = 5.days.ago.to_date

    calc = calculator_with_trades(security) do
      create_trade(security, account: @account, qty: 10,  price: 100, date: buy_date)
      create_trade(security, account: @account, qty: -5,  price: 120, date: sell_date)
    end

    # Sell does not change cost basis
    assert_in_delta 100.0, cost_basis_for(calc, security, sell_date).to_f, 1e-6
    assert_in_delta 100.0, cost_basis_for(calc, security, Date.current).to_f, 1e-6
  end

  test "cost_basis_for is nil while fully sold and resets after repurchase" do
    security = Security.create!(ticker: "TST", name: "Test")
    buy_date     = 10.days.ago.to_date
    sell_all_date = 6.days.ago.to_date
    rebuy_date   = 3.days.ago.to_date

    calc = calculator_with_trades(security) do
      create_trade(security, account: @account, qty: 10,  price: 100, date: buy_date)
      create_trade(security, account: @account, qty: -10, price: 130, date: sell_all_date) # fully sold
      create_trade(security, account: @account, qty: 10,  price: 150, date: rebuy_date)     # repurchased
    end

    assert_in_delta 100.0, cost_basis_for(calc, security, buy_date).to_f, 1e-6
    # Fully sold: no basis, not the stale $100 carried forward from the first buy
    assert_nil cost_basis_for(calc, security, sell_all_date)
    assert_nil cost_basis_for(calc, security, rebuy_date - 1)
    # Repurchased lot stands alone at $150, not (100 + 150) / 2 = $125
    assert_in_delta 150.0, cost_basis_for(calc, security, rebuy_date).to_f, 1e-6
    assert_in_delta 150.0, cost_basis_for(calc, security, Date.current).to_f, 1e-6
  end

  test "cost_basis_for relieves an outbound transfer instead of contaminating a later buy" do
    security = Security.create!(ticker: "TST", name: "Test")
    buy_date      = 10.days.ago.to_date
    transfer_date = 6.days.ago.to_date
    rebuy_date    = 3.days.ago.to_date

    calc = calculator_with_trades(security) do
      create_trade(security, account: @account, qty: 10, price: 100, date: buy_date)
      transfer_out = create_trade(security, account: @account, qty: -10, price: 120, date: transfer_date)
      transfer_out.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL) # transferred out, not sold
      create_trade(security, account: @account, qty: 10, price: 150, date: rebuy_date)
    end

    # Transferred-out lot is relieved, so the repurchase stands alone at $150.
    assert_in_delta 150.0, cost_basis_for(calc, security, rebuy_date).to_f, 1e-6
    assert_in_delta 150.0, cost_basis_for(calc, security, Date.current).to_f, 1e-6
  end

  test "cost_basis_for clears the unknown state once a transferred-in position is fully closed" do
    security = Security.create!(ticker: "TST", name: "Test")
    buy_date      = 12.days.ago.to_date
    transfer_date = 9.days.ago.to_date
    close_date    = 6.days.ago.to_date
    rebuy_date    = 3.days.ago.to_date

    calc = calculator_with_trades(security) do
      create_trade(security, account: @account, qty: 10, price: 100, date: buy_date)
      transfer_in = create_trade(security, account: @account, qty: 5, price: 120, date: transfer_date)
      transfer_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL) # moved in, unknown cost
      create_trade(security, account: @account, qty: -15, price: 130, date: close_date) # fully closed
      create_trade(security, account: @account, qty: 10, price: 150, date: rebuy_date)    # repurchased
    end

    # Trades net to 10, matching the 10-share snapshot, so the position really does
    # hit zero at the close before the repurchase.
    # Unknown while the transferred-in units are held
    assert_nil cost_basis_for(calc, security, transfer_date)
    assert_nil cost_basis_for(calc, security, close_date - 1)
    # Known again once the position is fully closed and bought back
    assert_in_delta 150.0, cost_basis_for(calc, security, rebuy_date).to_f, 1e-6
    assert_in_delta 150.0, cost_basis_for(calc, security, Date.current).to_f, 1e-6
  end

  # A reverse-synced account can hold shares before its first imported trade. Here
  # the snapshot is 10 but the trades net to only 8, so two shares predate the
  # history and the position never truly reaches zero — the transferred-in units
  # are still mixed in, so the basis must stay unknown.
  test "cost_basis_for keeps a transferred position unknown when opening shares prevent liquidation" do
    security = Security.create!(ticker: "TST", name: "Test")
    buy_date      = 12.days.ago.to_date
    transfer_date = 9.days.ago.to_date
    sell_date     = 6.days.ago.to_date
    rebuy_date    = 3.days.ago.to_date

    calc = calculator_with_trades(security) do
      create_trade(security, account: @account, qty: 10, price: 100, date: buy_date)
      transfer_in = create_trade(security, account: @account, qty: 5, price: 120, date: transfer_date)
      transfer_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL) # moved in, unknown cost
      create_trade(security, account: @account, qty: -15, price: 130, date: sell_date)
      create_trade(security, account: @account, qty: 8, price: 150, date: rebuy_date)
    end

    assert_nil cost_basis_for(calc, security, rebuy_date)
    assert_nil cost_basis_for(calc, security, Date.current)
  end

  # A gapped import can record more net buys than the current snapshot, so the
  # reconstructed baseline is negative. Opening and closing the unknown span must
  # not collapse onto the transfer's own trade, which would wrongly mark it known.
  test "cost_basis_for keeps a transferred position unknown when a gapped import gives a negative baseline" do
    security = Security.create!(ticker: "TST", name: "Test")
    transfer_date = 9.days.ago.to_date
    buy_date      = 5.days.ago.to_date

    transfer_in = create_trade(security, account: @account, qty: 5, price: 120, date: transfer_date)
    transfer_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL) # moved in, unknown cost
    create_trade(security, account: @account, qty: 5, price: 150, date: buy_date)

    # Snapshot shows no current holding, but the trades net to +10, so the seeded
    # baseline is -10 and the transfer lands while the running position is negative.
    snapshot = OpenStruct.new(to_h: { security.id => 0 })
    calc = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot)
    calc.send(:precompute_cost_basis)

    assert_nil cost_basis_for(calc, security, transfer_date)
    assert_nil cost_basis_for(calc, security, Date.current)
  end

  # --- Stock splits (#249) ---------------------------------------------------

  test "walking back past a 2-for-1 split halves the provider's share count" do
    security = split_security(before: 100, after: 50)
    create_trade(security, qty: 10, date: 4.days.ago.to_date, price: 100, account: @account)
    add_split(security, ex_date: 2.days.ago.to_date, numerator: 2, denominator: 1)

    holdings = reverse_holdings(security, today_qty: 20)

    assert_equal 20, holdings[Date.current].qty
    assert_equal 20, holdings[2.days.ago.to_date].qty
    assert_equal 10, holdings[3.days.ago.to_date].qty
    assert_equal 0, holdings[5.days.ago.to_date].qty, "the buy is undone in pre-split shares"
  end

  test "the cost per share halves at the split and the total cost does not move" do
    security = split_security(before: 100, after: 50)
    create_trade(security, qty: 10, date: 4.days.ago.to_date, price: 100, account: @account)
    add_split(security, ex_date: 2.days.ago.to_date, numerator: 2, denominator: 1)

    holdings = reverse_holdings(security, today_qty: 20)
    day_before = holdings[3.days.ago.to_date]
    ex_day = holdings[2.days.ago.to_date]

    assert_equal [ 100, 50 ], [ day_before.cost_basis, ex_day.cost_basis ]
    assert_equal day_before.qty * day_before.cost_basis, ex_day.qty * ex_day.cost_basis
  end

  test "walking back past a 1-for-10 reverse split multiplies the share count" do
    security = split_security(before: 5, after: 50)
    create_trade(security, qty: 100, date: 4.days.ago.to_date, price: 5, account: @account)
    add_split(security, ex_date: 2.days.ago.to_date, numerator: 1, denominator: 10)

    holdings = reverse_holdings(security, today_qty: 10)

    assert_equal [ 100, 10 ], [ holdings[3.days.ago.to_date].qty, holdings[2.days.ago.to_date].qty ]
    assert_equal [ 5, 50 ], [ holdings[3.days.ago.to_date].cost_basis, holdings[2.days.ago.to_date].cost_basis ]
  end

  # The walk starts at today and undoes its way back, so it reads whatever the
  # snapshot holds as today's position. A provider snapshot is regularly older
  # than that — a sync that failed and retried, or a provider that had not
  # refreshed — and a split in between has already changed the count it
  # reported. Read as current, the pre-split count became today's holding and
  # the walk then undid the same split again on the way past.
  test "a provider snapshot older than the split is brought forward before the walk" do
    security = Security.create!(ticker: "STAL", name: "Stale Snapshot")
    Security::Price.create!(security: security, date: 2.days.ago.to_date, price: 100)
    Security::Price.create!(security: security, date: 1.day.ago.to_date, price: 50)
    Security::Price.create!(security: security, date: Date.current, price: 50)

    # An entry so the walk reaches back past the snapshot's own day; account
    # history starts the day before the first entry.
    @account.entries.create!(
      name: "Opening", date: 4.days.ago.to_date, amount: 20000, currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    coinstats_item = @account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)
    @account.holdings.create!(
      security: security, date: 2.days.ago.to_date, qty: 10, price: 100, amount: 1000,
      currency: "USD", account_provider: account_provider
    )

    add_split(security, ex_date: 1.day.ago.to_date, numerator: 2, denominator: 1)

    holdings = Holding::ReverseCalculator
      .new(@account, portfolio_snapshot: Holding::PortfolioSnapshot.new(@account))
      .calculate
      .select { |h| h.security_id == security.id }
      .index_by(&:date)

    assert_equal 20, holdings[Date.current].qty, "the split the provider has already applied"
    assert_equal 1000, holdings[Date.current].amount, "20 shares at the post-split price"
    assert_equal 10, holdings[2.days.ago.to_date].qty, "the day the provider actually reported"
  end

  # An account with no entries starts yesterday, so its own history has no
  # splits before then. A provider snapshot from ten days ago, before a split
  # five days ago, still has to be brought through that split: the provider's
  # 10 shares are 20 today.
  test "a provider snapshot older than the account's history is still brought through a split" do
    security = Security.create!(ticker: "PRE", name: "Pre-start Split")
    Security::Price.create!(security: security, date: 1.day.ago.to_date, price: 50)
    Security::Price.create!(security: security, date: Date.current, price: 50)

    coinstats_item = @account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)
    @account.holdings.create!(
      security: security, date: 10.days.ago.to_date, qty: 10, price: 100, amount: 1000,
      currency: "USD", account_provider: account_provider
    )
    add_split(security, ex_date: 5.days.ago.to_date, numerator: 2, denominator: 1)
    assert_equal 1.day.ago.to_date, @account.start_date, "the split is before the account's history"

    holdings = Holding::ReverseCalculator
      .new(@account, portfolio_snapshot: Holding::PortfolioSnapshot.new(@account))
      .calculate
      .select { |h| h.security_id == security.id }
      .index_by(&:date)

    assert_equal 20, holdings[Date.current].qty
  end

  test "walking back past a 1-for-3 reverse split of one share gives exactly three" do
    security = split_security(before: 10, after: 30)
    create_trade(security, qty: 3, date: 4.days.ago.to_date, price: 10, account: @account)
    add_split(security, ex_date: 2.days.ago.to_date, numerator: 1, denominator: 3)

    holdings = reverse_holdings(security, today_qty: 1)

    assert_equal BigDecimal("3"), holdings[3.days.ago.to_date].qty
    # The cost-basis replay walks the same split both ways; 30.000...03 here
    # means it rounded.
    assert_equal BigDecimal("30"), holdings[2.days.ago.to_date].cost_basis
  end

  # The replay that tracks cost basis starts from the position before the first
  # trade, worked out from today's snapshot. Across a split that has to undo the
  # split too: 10 shares today, back through a rebuy of 10, a sale of 30, a
  # 2-for-1 split, a transfer in of 5 and a buy of 10, is 0 -- not the 15 that
  # "snapshot minus net trades" gives. From 15, the sale leaves 30 and the
  # transferred-in units are never cleared.
  test "a transferred-in position sold down after a split becomes known again on the rebuy" do
    security = Security.create!(ticker: "TST", name: "Test")
    buy_date      = 12.days.ago.to_date
    transfer_date = 9.days.ago.to_date
    ex_date       = 7.days.ago.to_date
    close_date    = 5.days.ago.to_date
    rebuy_date    = 3.days.ago.to_date

    calc = calculator_with_trades(security) do
      create_trade(security, account: @account, qty: 10, price: 100, date: buy_date)
      transfer_in = create_trade(security, account: @account, qty: 5, price: 120, date: transfer_date)
      transfer_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
      add_split(security, ex_date: ex_date, numerator: 2, denominator: 1)
      create_trade(security, account: @account, qty: -30, price: 65, date: close_date) # all 30 post-split shares
      create_trade(security, account: @account, qty: 10, price: 150, date: rebuy_date)
    end

    assert_nil cost_basis_for(calc, security, close_date - 1)
    assert_in_delta 150.0, cost_basis_for(calc, security, rebuy_date).to_f, 1e-6
  end

  # The replay decides a transferred-in position is sold out when it reaches
  # zero, so a split that leaves 1e-32 behind keeps the span unknown for ever.
  # 1-for-3 is undone to 3.000...03 by a Rational division (the seed walk), and
  # 2-for-3 applied to 2.000...01 by a Rational multiply (the replay).
  test "a transferred-in position sold to exactly zero after an uneven split becomes known again on the rebuy" do
    { [ 1, 3 ] => 1, [ 2, 3 ] => 2 }.each do |(numerator, denominator), sold|
      security = Security.create!(ticker: "TS#{numerator}", name: "Test #{numerator}-for-#{denominator}")
      close_date = 5.days.ago.to_date
      rebuy_date = 3.days.ago.to_date

      calc = calculator_with_trades(security) do
        transfer_in = create_trade(security, account: @account, qty: 3, price: 120, date: 9.days.ago.to_date)
        transfer_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
        add_split(security, ex_date: 7.days.ago.to_date, numerator: numerator, denominator: denominator)
        create_trade(security, account: @account, qty: -sold, price: 65, date: close_date)
        create_trade(security, account: @account, qty: 10, price: 150, date: rebuy_date)
      end

      assert_in_delta 150.0, cost_basis_for(calc, security, rebuy_date).to_f, 1e-6, "#{numerator}-for-#{denominator}"
    end
  end

  # The seed walk starts from the same position as the holdings walk: the
  # snapshot brought forward to today. Here the provider reported 10 shares the
  # day before a 2-for-1 split, so today is 20. Read as today's count, 10 was
  # halved back through the split to 5 and the seed came out at -5. The sale of
  # the transferred-in units then went from 0 to -5, never crossed zero, and the
  # rebuy stayed unknown for good.
  test "a provider snapshot older than the split seeds the cost-basis replay from today's count" do
    security = Security.create!(ticker: "STSD", name: "Stale Seed")
    transfer_date = 9.days.ago.to_date
    close_date    = 8.days.ago.to_date
    rebuy_date    = 7.days.ago.to_date

    transfer_in = create_trade(security, account: @account, qty: 5, price: 120, date: transfer_date)
    transfer_in.entryable.update!(investment_activity_label: Trade::TRANSFER_LABEL)
    create_trade(security, account: @account, qty: -5, price: 130, date: close_date)
    create_trade(security, account: @account, qty: 10, price: 150, date: rebuy_date)
    add_split(security, ex_date: 4.days.ago.to_date, numerator: 2, denominator: 1)

    snapshot = OpenStruct.new(to_h: { security.id => 10 }, effective_dates: { security.id => 6.days.ago.to_date })
    calc = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot)
    calc.send(:precompute_cost_basis)

    assert_nil cost_basis_for(calc, security, transfer_date)
    assert_in_delta 150.0, cost_basis_for(calc, security, rebuy_date).to_f, 1e-6
    assert_in_delta 75.0, cost_basis_for(calc, security, Date.current).to_f, 1e-6
  end

  # The provider reports nothing held today: the whole post-split position was
  # sold on the ex-date (Production Readiness Review on #253). Walking back, the
  # sale is undone first, in post-split shares, and then the split.
  test "a split and a sale of everything on the ex-date walk back to the pre-split position" do
    security = split_security(before: 100, after: 50)
    create_trade(security, qty: 10, date: 4.days.ago.to_date, price: 100, account: @account)
    add_split(security, ex_date: 2.days.ago.to_date, numerator: 2, denominator: 1)
    create_trade(security, qty: -20, date: 2.days.ago.to_date, price: 50, account: @account)

    holdings = reverse_holdings(security, today_qty: 0)

    assert_equal 0, holdings[2.days.ago.to_date].qty
    assert_equal 10, holdings[3.days.ago.to_date].qty, "20 sold, then halved back to 10"
    assert_equal 0, holdings[5.days.ago.to_date].qty
  end

  test "a split on one security leaves every other security's history as it was" do
    load_today_portfolio
    create_trade(@voo, qty: 5, date: 3.days.ago.to_date, price: 470, account: @account)
    create_trade(@wmt, qty: 10, date: 4.days.ago.to_date, price: 100, account: @account)
    wmt_split_date = 2.days.ago.to_date
    voo_rows = ->(holdings) { holdings.select { |h| h.security_id == @voo.id }.map { |h| [ h.date, h.qty, h.amount, h.cost_basis ] }.sort }
    snapshot = OpenStruct.new(to_h: { @voo.id => 10, @wmt.id => 100 })

    before = voo_rows.call(Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate)
    add_split(@wmt, ex_date: wmt_split_date, numerator: 2, denominator: 1)
    after = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate

    assert_equal before, voo_rows.call(after)
    assert_equal 50, after.find { |h| h.security_id == @wmt.id && h.date == wmt_split_date - 1 }.qty, "the split security itself did change"
  end

  private
    def split_security(before:, after:)
      security = Security.create!(ticker: "SPLT", name: "Split Test")
      (5.days.ago.to_date..Date.current).each do |date|
        Security::Price.create!(security: security, date: date, price: date < 2.days.ago.to_date ? before : after)
      end
      security
    end

    def add_split(security, ex_date:, numerator:, denominator:)
      Security::Split.create!(security: security, ex_date: ex_date, numerator: numerator, denominator: denominator, source: "manual")
    end

    # Today's row comes from the provider, as it does in a real reverse sync.
    def reverse_holdings(security, today_qty:)
      price = Security::Price.find_by!(security: security, date: Date.current).price
      @account.holdings.create!(security: security, date: Date.current, qty: today_qty, price: price, amount: today_qty * price, currency: "USD")
      snapshot = OpenStruct.new(to_h: { security.id => today_qty })
      Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot).calculate
        .select { |h| h.security_id == security.id }
        .index_by(&:date)
    end

    def assert_holdings(expected, calculated)
      expected.each do |expected_entry|
        calculated_entry = calculated.find { |c| c.security_id == expected_entry.security_id && c.date == expected_entry.date }
        assert_not_nil calculated_entry, "No calculated entry for security_id=#{expected_entry.security_id} on #{expected_entry.date}"

        assert_equal expected_entry.qty, calculated_entry.qty, "Qty mismatch for security_id=#{expected_entry.security_id} on #{expected_entry.date}"
        assert_equal expected_entry.price, calculated_entry.price, "Price mismatch for security_id=#{expected_entry.security_id} on #{expected_entry.date}"
        assert_equal expected_entry.amount, calculated_entry.amount, "Amount mismatch for security_id=#{expected_entry.security_id} on #{expected_entry.date}"
      end
    end

    def load_prices
      @voo = Security.create!(ticker: "VOO", name: "Vanguard S&P 500 ETF")
      Security::Price.create!(security: @voo, date: 4.days.ago.to_date, price: 460)
      Security::Price.create!(security: @voo, date: 3.days.ago.to_date, price: 470)
      Security::Price.create!(security: @voo, date: 2.days.ago.to_date, price: 480)
      Security::Price.create!(security: @voo, date: 1.day.ago.to_date, price: 490)
      Security::Price.create!(security: @voo, date: Date.current, price: 500)

      @wmt = Security.create!(ticker: "WMT", name: "Walmart Inc.")
      Security::Price.create!(security: @wmt, date: 4.days.ago.to_date, price: 100)
      Security::Price.create!(security: @wmt, date: 3.days.ago.to_date, price: 100)
      Security::Price.create!(security: @wmt, date: 2.days.ago.to_date, price: 100)
      Security::Price.create!(security: @wmt, date: 1.day.ago.to_date, price: 100)
      Security::Price.create!(security: @wmt, date: Date.current, price: 100)

      @amzn = Security.create!(ticker: "AMZN", name: "Amazon.com Inc.")
      Security::Price.create!(security: @amzn, date: 4.days.ago.to_date, price: 200)
      Security::Price.create!(security: @amzn, date: 3.days.ago.to_date, price: 200)
      Security::Price.create!(security: @amzn, date: 2.days.ago.to_date, price: 200)
      Security::Price.create!(security: @amzn, date: 1.day.ago.to_date, price: 200)
      Security::Price.create!(security: @amzn, date: Date.current, price: 200)
    end

    # Portfolio holdings:
    # +--------+-----+--------+---------+
    # | Ticker | Qty | Price  | Amount  |
    # +--------+-----+--------+---------+
    # | VOO    |  10 | $500   | $5,000  |
    # | WMT    | 100 | $100   | $10,000 |
    # +--------+-----+--------+---------+
    # Brokerage Cash: $5,000
    # Holdings Value: $15,000
    # Total Balance: $20,000
    def calculator_with_trades(security)
      yield if block_given?
      snapshot = OpenStruct.new(to_h: { security.id => 10 })
      calc = Holding::ReverseCalculator.new(@account, portfolio_snapshot: snapshot)
      calc.send(:precompute_cost_basis)
      calc
    end

    def cost_basis_for(calc, security, date)
      calc.send(:cost_basis_for, security.id, date)
    end

    def load_today_portfolio
      @account.update!(cash_balance: 5000)

      load_prices

      @account.holdings.create!(
        date: Date.current,
        price: 500,
        qty: 10,
        amount: 5000,
        currency: "USD",
        security: @voo
      )

      @account.holdings.create!(
        date: Date.current,
        price: 100,
        qty: 100,
        amount: 10000,
        currency: "USD",
        security: @wmt
      )
    end
end
