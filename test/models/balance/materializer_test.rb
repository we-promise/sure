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
      Balance::BalanceData.new(
        account: @account, date: 1.day.ago.to_date, balance: 1000, cash_balance: 1000, currency: "USD",
        start_cash_balance: 500, start_non_cash_balance: 0, cash_inflows: 500,
        cash_outflows: 0, non_cash_inflows: 0, non_cash_outflows: 0,
        net_market_flows: 0, cash_adjustments: 0, non_cash_adjustments: 0, flows_factor: 1
      ),
      Balance::BalanceData.new(
        account: @account, date: Date.current, balance: 1000, cash_balance: 1000, currency: "USD",
        start_cash_balance: 1000, start_non_cash_balance: 0, cash_inflows: 0,
        cash_outflows: 0, non_cash_inflows: 0, non_cash_outflows: 0,
        net_market_flows: 0, cash_adjustments: 0, non_cash_adjustments: 0, flows_factor: 1
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
      Balance::BalanceData.new(
        account: @account, date: 2.days.ago.to_date, balance: 15000, cash_balance: 15000, currency: "USD",
        start_cash_balance: 12000, start_non_cash_balance: 0, cash_inflows: 3000,
        cash_outflows: 0, non_cash_inflows: 0, non_cash_outflows: 0,
        net_market_flows: 0, cash_adjustments: 0, non_cash_adjustments: 0, flows_factor: 1
      )
    ]

    Balance::ForwardCalculator.any_instance.expects(:calculate).returns(recalculated)
    Balance::ForwardCalculator.any_instance.stubs(:incremental?).returns(true)
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

  # Regression: a prior full sync materializes balances for entries dated BEFORE
  # the opening anchor; a later incremental sync (window after the anchor) must
  # preserve them. The purge lower bound uses calculation_start_date — the same
  # bound the calculator uses — not opening_anchor_date.
  test "incremental sync preserves balances dated before the opening anchor" do
    # Opening anchor at 5.days.ago, but a reconciliation backfilled earlier.
    @account.entries.create!(
      name: "Opening Balance", date: 5.days.ago.to_date, amount: 5000,
      currency: "USD", entryable: Valuation.new(kind: "opening_anchor")
    )
    @account.entries.create!(
      name: "Backfilled reconciliation", date: 8.days.ago.to_date, amount: 3000,
      currency: "USD", entryable: Valuation.new(kind: "reconciliation")
    )

    # Pre-anchor balance materialized by a prior full sync.
    pre_anchor    = create_balance(account: @account, date: 8.days.ago.to_date, balance: 3000)
    preserved_mid = create_balance(account: @account, date: 6.days.ago.to_date, balance: 4000)

    recalculated = [
      Balance::BalanceData.new(
        account: @account,
        date: 2.days.ago.to_date, balance: 15000, cash_balance: 15000, currency: "USD",
        start_cash_balance: 12000, start_non_cash_balance: 0,
        cash_inflows: 3000, cash_outflows: 0, non_cash_inflows: 0, non_cash_outflows: 0,
        net_market_flows: 0, cash_adjustments: 0, non_cash_adjustments: 0, flows_factor: 1
      )
    ]

    Balance::ForwardCalculator.any_instance.expects(:calculate).returns(recalculated)
    Balance::ForwardCalculator.any_instance.stubs(:incremental?).returns(true)
    Holding::Materializer.any_instance.expects(:materialize_holdings).returns([]).once

    Balance::Materializer.new(@account, strategy: :forward, window_start_date: 2.days.ago.to_date).materialize_balances

    assert_not_nil @account.balances.find_by(id: pre_anchor.id),
      "Balance before the opening anchor must be preserved during incremental purge"
    assert_not_nil @account.balances.find_by(id: preserved_mid.id),
      "Balance between anchor and window must be preserved"
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

    # No prior balance exists for window_start_date - 1 (3.days.ago) → calculator falls back to full recalc.
    Balance::Materializer.new(@account, strategy: :forward, window_start_date: 2.days.ago.to_date).materialize_balances

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
      Balance::BalanceData.new(
        account: @account, date: 2.days.ago.to_date, balance: 10000, cash_balance: 10000, currency: "USD",
        start_cash_balance: 10000, start_non_cash_balance: 0, cash_inflows: 0,
        cash_outflows: 0, non_cash_inflows: 0, non_cash_outflows: 0,
        net_market_flows: 0, cash_adjustments: 0, non_cash_adjustments: 0, flows_factor: 1
      ),
      Balance::BalanceData.new(
        account: @account, date: 1.day.ago.to_date, balance: 1000, cash_balance: 1000, currency: "USD",
        start_cash_balance: 10000, start_non_cash_balance: 0, cash_inflows: 0,
        cash_outflows: 9000, non_cash_inflows: 0, non_cash_outflows: 0,
        net_market_flows: 0, cash_adjustments: 0, non_cash_adjustments: 0, flows_factor: 1
      ),
      Balance::BalanceData.new(
        account: @account, date: Date.current, balance: 1000, cash_balance: 1000, currency: "USD",
        start_cash_balance: 1000, start_non_cash_balance: 0, cash_inflows: 0,
        cash_outflows: 0, non_cash_inflows: 0, non_cash_outflows: 0,
        net_market_flows: 0, cash_adjustments: 0, non_cash_adjustments: 0, flows_factor: 1
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

  test "reverse materialization persists opening boundary adjustment" do
    account = families(:empty).accounts.create!(
      name: "Linked Depository",
      balance: 1000,
      cash_balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )
    opening_date = Date.new(2024, 1, 1)
    boundary_date = opening_date + 1.day
    transaction_date = opening_date + 2.days
    current_anchor_date = opening_date + 3.days

    account.entries.create!(
      name: "Current Balance",
      date: current_anchor_date,
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "current_anchor")
    )
    account.entries.create!(
      name: "Transaction",
      date: transaction_date,
      amount: 200,
      currency: "USD",
      entryable: Transaction.new
    )
    account.entries.create!(
      name: "Opening Balance",
      date: opening_date,
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    Holding::Materializer.any_instance.expects(:materialize_holdings).returns([]).once

    Balance::Materializer.new(account, strategy: :reverse).materialize_balances

    opening_balance = account.balances.find_by!(date: opening_date)
    boundary_balance = account.balances.find_by!(date: boundary_date)
    transaction_balance = account.balances.find_by!(date: transaction_date)

    assert_equal 1000, opening_balance.end_balance
    assert_equal 1000, boundary_balance.start_balance
    assert_equal 1200, boundary_balance.end_balance
    assert_equal 200, boundary_balance.cash_adjustments
    assert_equal 0, boundary_balance.cash_inflows
    assert_equal 0, boundary_balance.cash_outflows
    assert_equal 1200, transaction_balance.start_balance
    assert_equal 1000, transaction_balance.end_balance
  end


  # A linked account whose provider sends balances but no positions (SimpleFIN,
  # LunchFlow and similar) had no holdings at all: the reverse holdings
  # calculator needs a provider snapshot, so recorded trades never became
  # positions and the whole balance showed as cash (#4302).
  test "a linked account with trades and no provider snapshot materializes positions from trades" do
    account, security = linked_account_with_trade

    Balance::Materializer.new(account, strategy: :reverse).materialize_balances

    account.reload
    holding = account.current_holdings.find_by(security: security)
    assert_not_nil holding, "the trade should produce a position"
    assert_equal 2, holding.qty
    # Cash is what the holdings leave of the provider's balance on its anchor
    # date (yesterday, price 200), the newest balance row.
    assert_equal 10_000 - 2 * 200, account.cash_balance
    assert_equal 10_000 - 2 * 200, account.balances.order(date: :desc).first.end_cash_balance
    # The provider's balance stays the total. A forward run would recompute it
    # from today's price, which moved after the anchor.
    assert_equal 10_000, account.balance
  end

  test "a linked account with a provider snapshot keeps the provider's holdings and cash" do
    account, security = linked_account_with_trade
    account.update_columns(cash_balance: 3_000)
    account.holdings.create!(
      security: security, date: Date.current, qty: 5, price: 210, amount: 1_050, currency: "USD",
      account_provider: account.account_providers.first
    )

    Balance::Materializer.new(account, strategy: :reverse).materialize_balances

    account.reload
    assert_equal 5, account.current_holdings.find_by(security: security).qty
    assert_equal 3_000, account.cash_balance
  end

  test "a linked account with no provider snapshot and no trades gets no holdings and no cash write" do
    account = linked_investment_account
    # A provider figure that differs from the balance, so a write would show.
    account.update_columns(cash_balance: 7_000)
    create_valuation(account: account, amount: 10_000, date: 1.day.ago.to_date, kind: "current_anchor")

    Balance::Materializer.new(account, strategy: :reverse).materialize_balances

    account.reload
    assert_empty account.holdings
    assert_equal 7_000, account.cash_balance
  end

  test "a provider snapshot arriving after trade-derived positions replaces them without double counting" do
    account, security = linked_account_with_trade
    Balance::Materializer.new(account, strategy: :reverse).materialize_balances
    account.reload.update_columns(cash_balance: 4_000)

    # As the provider import does: it writes onto today's row for the security.
    account.holdings.find_or_initialize_by(security: security, date: Date.current, currency: "USD").update!(
      qty: 3, price: 210, amount: 630, account_provider: account.account_providers.first
    )
    Balance::Materializer.new(account, strategy: :reverse).materialize_balances

    account.reload
    rows = account.current_holdings.where(security: security).to_a
    assert_equal [ 3 ], rows.map(&:qty)
    assert_equal 4_000, account.cash_balance
  end

  test "the trade fallback purges a leftover calculated row for a security with no trades" do
    account, _security = linked_account_with_trade
    stale = Security.create!(ticker: "STALEX", name: "Stale")
    account.holdings.create!(security: stale, date: 3.days.ago.to_date, qty: 0, price: 10, amount: 0, currency: "USD")

    Balance::Materializer.new(account, strategy: :reverse).materialize_balances

    assert_not account.holdings.exists?(security: stale)
  end

  # A provider's trade history can start after a position was opened (Plaid
  # sends at most two years), so a sell can arrive without its buy. Built from
  # zero that is a negative position, and cash above the provider's total. The
  # fallback stands aside and the account reads as it did without it.
  test "a sell without its buy leaves the account as it was, with no negative position" do
    account = linked_investment_account
    security = Security.create!(ticker: "SOLDX", name: "Sold")
    (5.days.ago.to_date..Date.current).each { |date| Security::Price.create!(security: security, date: date, price: 200) }
    create_trade(security, account: account, qty: -2, date: 3.days.ago.to_date, price: 200)
    create_valuation(account: account, amount: 10_000, date: 1.day.ago.to_date, kind: "current_anchor")

    Balance::Materializer.new(account, strategy: :reverse).materialize_balances

    account.reload
    assert_not account.holdings.where("qty < 0").exists?, "no negative position is stored"
    assert_equal 10_000, account.cash_balance
  end

  # The guard reads the position the trades actually build. Summing trade
  # quantities would call this one negative (2 - 3), but the 2:1 split between
  # them leaves one share.
  test "a position a split carries through a larger sell still builds from trades" do
    account = linked_investment_account
    security = Security.create!(ticker: "SPLTX", name: "Split")
    (5.days.ago.to_date..Date.current).each { |date| Security::Price.create!(security: security, date: date, price: 100) }
    create_trade(security, account: account, qty: 2, date: 5.days.ago.to_date, price: 200)
    security.splits.create!(ex_date: 3.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    create_trade(security, account: account, qty: -3, date: 2.days.ago.to_date, price: 100)
    create_valuation(account: account, amount: 10_000, date: 1.day.ago.to_date, kind: "current_anchor")

    Balance::Materializer.new(account, strategy: :reverse).materialize_balances

    assert_equal 1, account.reload.current_holdings.find_by!(security: security).qty
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

    def linked_investment_account
      account = families(:empty).accounts.create!(
        name: "Linked brokerage", balance: 10_000, cash_balance: 10_000, currency: "USD", accountable: Investment.new
      )
      item = account.family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
      account.account_providers.create!(provider: item.coinstats_accounts.create!(name: "Provider", currency: "USD"))
      account
    end

    # Bought 2 at 200 five days ago; the price is 200 until yesterday's
    # balance anchor and 210 today.
    def linked_account_with_trade
      account = linked_investment_account
      security = Security.create!(ticker: "TRDX", name: "Traded")
      (5.days.ago.to_date..1.day.ago.to_date).each { |date| Security::Price.create!(security: security, date: date, price: 200) }
      Security::Price.create!(security: security, date: Date.current, price: 210)
      create_trade(security, account: account, qty: 2, date: 5.days.ago.to_date, price: 200)
      create_valuation(account: account, amount: 10_000, date: 1.day.ago.to_date, kind: "current_anchor")
      [ account, security ]
    end
end
