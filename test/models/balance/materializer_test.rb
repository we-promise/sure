require "test_helper"

class Balance::MaterializerTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include BalanceTestHelper

  setup do
    @account = families(:empty).accounts.create!(
      name: "Test",
      balance: 20000,
      cash_balance: 20000,
      currency: "USD",
      accountable: Investment.new
    )
  end

  test "syncs balances" do
    Holding::Materializer.any_instance.expects(:materialize_holdings).returns([]).once

    expected_balances = [
      Balance.new(
        date: 1.day.ago.to_date,
        balance: 1000,
        cash_balance: 1000,
        currency: "USD",
        start_cash_balance: 500,
        start_non_cash_balance: 0,
        cash_inflows: 500,
        cash_outflows: 0,
        non_cash_inflows: 0,
        non_cash_outflows: 0,
        net_market_flows: 0,
        cash_adjustments: 0,
        non_cash_adjustments: 0,
        flows_factor: 1
      ),
      Balance.new(
        date: Date.current,
        balance: 1000,
        cash_balance: 1000,
        currency: "USD",
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
    ]

    Balance::ForwardCalculator.any_instance.expects(:calculate).returns(expected_balances)

    assert_difference "@account.balances.count", 2 do
      Balance::Materializer.new(@account, strategy: :forward).materialize_balances
    end

    assert_balance_fields_persisted(expected_balances)
  end

  test "incremental sync preserves balances before window_start_date and purges only beyond calc_end_date" do
    # Add an opening anchor so opening_anchor_date is well in the past.
    @account.entries.create!(
      name: "Opening Balance",
      date: 10.days.ago.to_date,
      amount: 5000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    preserved_old  = create_balance(account: @account, date: 5.days.ago.to_date, balance: 10000)
    preserved_mid  = create_balance(account: @account, date: 3.days.ago.to_date, balance: 12000)
    stale_future   = create_balance(account: @account, date: 5.days.from_now.to_date, balance: 99000)

    # Calculator returns only the window being recalculated (2.days.ago).
    recalculated = [
      Balance.new(
        date: 2.days.ago.to_date,
        balance: 15000,
        cash_balance: 15000,
        currency: "USD",
        start_cash_balance: 12000,
        start_non_cash_balance: 0,
        cash_inflows: 3000,
        cash_outflows: 0,
        non_cash_inflows: 0,
        non_cash_outflows: 0,
        net_market_flows: 0,
        cash_adjustments: 0,
        non_cash_adjustments: 0,
        flows_factor: 1
      )
    ]

    Balance::ForwardCalculator.any_instance.expects(:calculate).returns(recalculated)
    Holding::Materializer.any_instance.expects(:materialize_holdings).returns([]).once

    Balance::Materializer.new(@account, strategy: :forward, window_start_date: 2.days.ago.to_date).materialize_balances

    # Balances before window_start_date must be preserved.
    assert_not_nil @account.balances.find_by(id: preserved_old.id),
      "Balance at 5.days.ago should be preserved (before window_start_date)"
    assert_not_nil @account.balances.find_by(id: preserved_mid.id),
      "Balance at 3.days.ago should be preserved (before window_start_date)"

    # Balance after calc_end_date must be purged.
    assert_nil @account.balances.find_by(id: stale_future.id),
      "Balance at 5.days.from_now should be purged (after calc_end_date)"

    # Recalculated balance must be present.
    assert_not_nil @account.balances.find_by(date: 2.days.ago.to_date),
      "Recalculated balance for 2.days.ago should be persisted"
  end

  test "falls back to full recalculation when window_start_date is given but no prior balance exists" do
    @account.entries.create!(
      name: "Opening Balance",
      date: 5.days.ago.to_date,
      amount: 20000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    @account.entries.create!(
      name: "Test transaction",
      date: 3.days.ago.to_date,
      amount: -1000,
      currency: "USD",
      entryable: Transaction.new
    )

    # A stale pre-window balance with a wrong value.
    # In successful incremental mode this would be preserved as-is;
    # in fallback (no prior balance) the full recalc must overwrite it.
    wrong_pre_window = create_balance(account: @account, date: 4.days.ago.to_date, balance: 99999)

    # A stale balance before opening_anchor_date — must be purged in both modes.
    stale_before_anchor = create_balance(account: @account, date: 8.days.ago.to_date, balance: 99999)

    Holding::Materializer.any_instance.stubs(:materialize_holdings).returns([])

    # No prior balance exists for window_start_date - 1 (4.days.ago) → calculator falls back to full recalc.
    Balance::Materializer.new(@account, strategy: :forward, window_start_date: 3.days.ago.to_date).materialize_balances

    # After fallback the pre-window balance must be recalculated with the correct value, not preserved.
    recalculated = @account.balances.find_by(date: wrong_pre_window.date)
    assert_not_nil recalculated, "Balance at 4.days.ago should exist after full recalculation"
    assert_equal 20000, recalculated.balance, "Balance should reflect full recalculation, not the stale value (99999)"

    # Stale balance before opening_anchor_date should be purged.
    assert_nil @account.balances.find_by(id: stale_before_anchor.id),
      "Balance before opening_anchor_date should be purged"
  end

  test "purges stale balances outside calculated range" do
    # Create existing balances that will be stale
    stale_old = create_balance(account: @account, date: 5.days.ago.to_date, balance: 5000)
    stale_future = create_balance(account: @account, date: 2.days.from_now.to_date, balance: 15000)

    # Calculator will return balances for only these dates
    expected_balances = [
      Balance.new(
        date: 2.days.ago.to_date,
        balance: 10000,
        cash_balance: 10000,
        currency: "USD",
        start_cash_balance: 10000,
        start_non_cash_balance: 0,
        cash_inflows: 0,
        cash_outflows: 0,
        non_cash_inflows: 0,
        non_cash_outflows: 0,
        net_market_flows: 0,
        cash_adjustments: 0,
        non_cash_adjustments: 0,
        flows_factor: 1
      ),
      Balance.new(
        date: 1.day.ago.to_date,
        balance: 1000,
        cash_balance: 1000,
        currency: "USD",
        start_cash_balance: 10000,
        start_non_cash_balance: 0,
        cash_inflows: 0,
        cash_outflows: 9000,
        non_cash_inflows: 0,
        non_cash_outflows: 0,
        net_market_flows: 0,
        cash_adjustments: 0,
        non_cash_adjustments: 0,
        flows_factor: 1
      ),
      Balance.new(
        date: Date.current,
        balance: 1000,
        cash_balance: 1000,
        currency: "USD",
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
    ]

    Balance::ForwardCalculator.any_instance.expects(:calculate).returns(expected_balances)
    Holding::Materializer.any_instance.expects(:materialize_holdings).returns([]).once

    # Should end up with 3 balances (stale ones deleted, new ones created)
    assert_difference "@account.balances.count", 1 do
      Balance::Materializer.new(@account, strategy: :forward).materialize_balances
    end

    # Verify stale balances were deleted
    assert_nil @account.balances.find_by(id: stale_old.id)
    assert_nil @account.balances.find_by(id: stale_future.id)

    # Verify expected balances were persisted
    assert_balance_fields_persisted(expected_balances)
  end

  private

    def assert_balance_fields_persisted(expected_balances)
      expected_balances.each do |expected|
        persisted = @account.balances.find_by(date: expected.date)
        assert_not_nil persisted, "Balance for #{expected.date} should be persisted"

        # Check all balance component fields
        assert_equal expected.balance, persisted.balance
        assert_equal expected.cash_balance, persisted.cash_balance
        assert_equal expected.start_cash_balance, persisted.start_cash_balance
        assert_equal expected.start_non_cash_balance, persisted.start_non_cash_balance
        assert_equal expected.cash_inflows, persisted.cash_inflows
        assert_equal expected.cash_outflows, persisted.cash_outflows
        assert_equal expected.non_cash_inflows, persisted.non_cash_inflows
        assert_equal expected.non_cash_outflows, persisted.non_cash_outflows
        assert_equal expected.net_market_flows, persisted.net_market_flows
        assert_equal expected.cash_adjustments, persisted.cash_adjustments
        assert_equal expected.non_cash_adjustments, persisted.non_cash_adjustments
        assert_equal expected.flows_factor, persisted.flows_factor
      end
    end
end
