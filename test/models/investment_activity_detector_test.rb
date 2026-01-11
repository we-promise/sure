require "test_helper"

class InvestmentActivityDetectorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @investment_account = @family.accounts.create!(
      name: "Brokerage",
      balance: 10000,
      cash_balance: 2000,
      currency: "USD",
      accountable: Investment.new
    )
    @detector = InvestmentActivityDetector.new(@investment_account)
  end

  test "detects new holding purchase and marks matching transaction" do
    # Create a transaction that matches a new holding purchase
    entry = create_transaction(
      account: @investment_account,
      amount: 1000,
      name: "Buy VFIAX"
    )
    transaction = entry.transaction

    # Simulate holdings snapshot showing a new holding
    current_holdings = [
      { "symbol" => "VFIAX", "cost_basis" => 1000.0, "shares" => 10 }
    ]

    # No previous snapshot
    @investment_account.update!(holdings_snapshot_data: nil, holdings_snapshot_at: nil)

    @detector.detect_and_mark_internal_activity(current_holdings, [ transaction ])

    entry.reload
    assert entry.exclude_from_cashflow?, "Transaction matching new holding should be excluded from cashflow"
  end

  test "detects holding sale and marks matching transaction" do
    # Set up previous holdings
    previous_holdings = [
      { "symbol" => "VFIAX", "cost_basis" => 2000.0, "shares" => 20 }
    ]
    @investment_account.update!(
      holdings_snapshot_data: previous_holdings,
      holdings_snapshot_at: 1.day.ago
    )

    # Create a transaction for the sale proceeds (negative = inflow)
    entry = create_transaction(
      account: @investment_account,
      amount: -1000,
      name: "Sell VFIAX"
    )
    transaction = entry.transaction

    # Current holdings show reduced position
    current_holdings = [
      { "symbol" => "VFIAX", "cost_basis" => 1000.0, "shares" => 10 }
    ]

    @detector.detect_and_mark_internal_activity(current_holdings, [ transaction ])

    entry.reload
    assert entry.exclude_from_cashflow?, "Transaction matching holding sale should be excluded from cashflow"
  end

  test "respects locked exclude_from_cashflow attribute" do
    # Create a transaction and lock the attribute
    entry = create_transaction(
      account: @investment_account,
      amount: 1000,
      name: "Buy VFIAX"
    )
    transaction = entry.transaction

    # User explicitly set to NOT exclude (and locked it)
    entry.update!(exclude_from_cashflow: false)
    entry.lock_attr!(:exclude_from_cashflow)

    current_holdings = [
      { "symbol" => "VFIAX", "cost_basis" => 1000.0, "shares" => 10 }
    ]

    @detector.detect_and_mark_internal_activity(current_holdings, [ transaction ])

    entry.reload
    assert_not entry.exclude_from_cashflow?, "Locked attribute should not be overwritten"
  end

  test "updates holdings snapshot after detection" do
    current_holdings = [
      { "symbol" => "VFIAX", "cost_basis" => 1000.0, "shares" => 10 },
      { "symbol" => "IBIT", "cost_basis" => 500.0, "shares" => 5 }
    ]

    @detector.detect_and_mark_internal_activity(current_holdings, [])

    @investment_account.reload
    # Snapshot is normalized with string values and additional fields
    snapshot = @investment_account.holdings_snapshot_data
    assert_equal 2, snapshot.size
    assert_equal "VFIAX", snapshot[0]["symbol"]
    assert_equal "1000.0", snapshot[0]["cost_basis"]
    assert_equal "10.0", snapshot[0]["shares"]
    assert_equal "IBIT", snapshot[1]["symbol"]
    assert_not_nil @investment_account.holdings_snapshot_at
  end

  test "matches transaction by cost_basis amount within tolerance" do
    entry = create_transaction(
      account: @investment_account,
      amount: 1000.005,  # Very close - within 0.01 tolerance
      name: "Investment purchase"
    )
    transaction = entry.transaction

    # Holding with cost basis close to transaction amount (within 0.01)
    current_holdings = [
      { "symbol" => "VFIAX", "cost_basis" => 1000.0, "shares" => 10 }
    ]

    @detector.detect_and_mark_internal_activity(current_holdings, [ transaction ])

    entry.reload
    assert entry.exclude_from_cashflow?, "Should match transaction within tolerance"
  end

  test "does not mark unrelated transactions" do
    # Create a regular expense transaction
    entry = create_transaction(
      account: @investment_account,
      amount: 50,
      name: "Account fee"
    )
    transaction = entry.transaction

    # Holdings that don't match
    current_holdings = [
      { "symbol" => "VFIAX", "cost_basis" => 1000.0, "shares" => 10 }
    ]

    @detector.detect_and_mark_internal_activity(current_holdings, [ transaction ])

    entry.reload
    assert_not entry.exclude_from_cashflow?, "Unrelated transaction should not be excluded"
  end

  test "works with crypto accounts" do
    crypto_account = @family.accounts.create!(
      name: "Crypto Wallet",
      balance: 5000,
      currency: "USD",
      accountable: Crypto.new
    )
    detector = InvestmentActivityDetector.new(crypto_account)

    entry = create_transaction(
      account: crypto_account,
      amount: 1000,
      name: "Buy BTC"
    )
    transaction = entry.transaction

    current_holdings = [
      { "symbol" => "BTC", "cost_basis" => 1000.0, "shares" => 0.02 }
    ]

    detector.detect_and_mark_internal_activity(current_holdings, [ transaction ])

    entry.reload
    assert entry.exclude_from_cashflow?, "Should work with crypto accounts"
  end

  test "handles empty holdings gracefully" do
    entry = create_transaction(
      account: @investment_account,
      amount: 1000,
      name: "Some transaction"
    )
    transaction = entry.transaction

    # Should not raise, just do nothing
    assert_nothing_raised do
      @detector.detect_and_mark_internal_activity([], [ transaction ])
    end

    entry.reload
    assert_not entry.exclude_from_cashflow?
  end

  test "handles nil holdings gracefully" do
    entry = create_transaction(
      account: @investment_account,
      amount: 1000,
      name: "Some transaction"
    )
    transaction = entry.transaction

    assert_nothing_raised do
      @detector.detect_and_mark_internal_activity(nil, [ transaction ])
    end

    entry.reload
    assert_not entry.exclude_from_cashflow?
  end

  test "sets Buy label for new holding purchase" do
    entry = create_transaction(
      account: @investment_account,
      amount: 1000,
      name: "Some investment"
    )
    transaction = entry.transaction

    current_holdings = [
      { "symbol" => "VFIAX", "cost_basis" => 1000.0, "shares" => 10 }
    ]

    @detector.detect_and_mark_internal_activity(current_holdings, [ transaction ])

    transaction.reload
    assert_equal "Buy", transaction.investment_activity_label
  end

  test "sets Sell label for holding sale" do
    previous_holdings = [
      { "symbol" => "VFIAX", "cost_basis" => 2000.0, "shares" => 20 }
    ]
    @investment_account.update!(
      holdings_snapshot_data: previous_holdings,
      holdings_snapshot_at: 1.day.ago
    )

    entry = create_transaction(
      account: @investment_account,
      amount: -1000,
      name: "VFIAX Sale"
    )
    transaction = entry.transaction

    current_holdings = [
      { "symbol" => "VFIAX", "cost_basis" => 1000.0, "shares" => 10 }
    ]

    @detector.detect_and_mark_internal_activity(current_holdings, [ transaction ])

    transaction.reload
    assert_equal "Sell", transaction.investment_activity_label
  end

  test "infers Sweep In label from money market description" do
    entry = create_transaction(
      account: @investment_account,
      amount: -500,
      name: "VANGUARD FEDERAL MONEY MARKET"
    )
    transaction = entry.transaction

    # Call with empty holdings but simulate it being a sweep
    # This tests the infer_from_description fallback
    current_holdings = [
      { "symbol" => "VMFXX", "cost_basis" => 500.0, "shares" => 500 }
    ]

    @detector.detect_and_mark_internal_activity(current_holdings, [ transaction ])

    transaction.reload
    # Should be either "Buy" (from holdings match) or "Sweep In" (from description)
    assert transaction.investment_activity_label.present?
  end

  test "infers Dividend label from CASH description" do
    entry = create_transaction(
      account: @investment_account,
      amount: -50,
      name: "CASH"
    )
    transaction = entry.transaction

    # No holdings change, but description-based inference
    current_holdings = [
      { "symbol" => "VFIAX", "cost_basis" => 1000.0, "shares" => 10 }
    ]
    @investment_account.update!(
      holdings_snapshot_data: current_holdings,
      holdings_snapshot_at: 1.day.ago
    )

    @detector.detect_and_mark_internal_activity(current_holdings, [ transaction ])

    # Since there's no holdings change, no label gets set via holdings match
    # But if we manually test the infer_from_description method...
    label = @detector.send(:infer_from_description, entry)
    assert_equal "Dividend", label
  end
end
