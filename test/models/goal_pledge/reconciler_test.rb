require "test_helper"

class GoalPledge::ReconcilerTest < ActiveSupport::TestCase
  include GoalPledgeTestHelper

  setup do
    @pledge = goal_pledges(:open_transfer)
    @account = @pledge.account
  end

  test "matches and stamps a posted Transaction within tolerance" do
    entry = create_transaction_entry(amount: -200, date: @pledge.created_at.to_date)

    GoalPledge::Reconciler.new(entry).run

    assert_equal @pledge.id, entry.transaction.reload.extra.dig("goal", "pledge_id")
    assert @pledge.reload.status_matched?
    assert_equal entry.transaction.id, @pledge.matched_transaction_id
  end

  test "skips entries already stamped with a pledge_id" do
    entry = create_transaction_entry(amount: -200, date: @pledge.created_at.to_date)
    entry.transaction.update!(extra: { "goal" => { "pledge_id" => "abc" } })

    GoalPledge::Reconciler.new(entry).run

    assert_equal "abc", entry.transaction.reload.extra.dig("goal", "pledge_id")
    assert_not @pledge.reload.status_matched?
  end

  test "skips pledges outside amount tolerance" do
    entry = create_transaction_entry(amount: -300, date: @pledge.created_at.to_date)

    GoalPledge::Reconciler.new(entry).run

    assert_not @pledge.reload.status_matched?
    assert_nil entry.transaction.reload.extra.dig("goal", "pledge_id")
  end

  test "skips entries on accounts with no open pledges" do
    other_account = accounts(:investment)
    entry = create_transaction_entry(amount: -200, date: Date.current, account: other_account)

    GoalPledge::Reconciler.new(entry).run

    assert_not @pledge.reload.status_matched?
  end

  test "ignores excluded entries" do
    entry = create_transaction_entry(amount: -200, date: @pledge.created_at.to_date, excluded: true)

    GoalPledge::Reconciler.new(entry).run

    assert_not @pledge.reload.status_matched?
  end

  test "manual_save kind matches a Valuation by its contribution delta, not the full balance" do
    manual_pledge = @pledge.goal.goal_pledges.create!(
      account: @account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    # Realistic reconciliation: the account already held $2,000 and the user
    # bumps it to $2,150. The valuation records the full $2,150 total; the
    # $150 contribution is the delta the manager passes in.
    entry = create_valuation_entry(amount: 2150, date: manual_pledge.created_at.to_date)

    GoalPledge::Reconciler.new(entry, valuation_delta: 150).run

    assert manual_pledge.reload.status_matched?
  end

  test "manual_save kind does not match when the full balance (not the delta) is unrelated to the pledge" do
    manual_pledge = @pledge.goal.goal_pledges.create!(
      account: @account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    entry = create_valuation_entry(amount: 2150, date: manual_pledge.created_at.to_date)

    # The full $2,150 balance must never be mistaken for the $150 contribution.
    GoalPledge::Reconciler.new(entry, valuation_delta: 2150).run

    assert_not manual_pledge.reload.status_matched?
  end

  test "manual_save kind does not match a balance decrease" do
    manual_pledge = @pledge.goal.goal_pledges.create!(
      account: @account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    entry = create_valuation_entry(amount: 1850, date: manual_pledge.created_at.to_date)

    # Balance dropped by $150 — a drawdown must not resolve a save pledge.
    GoalPledge::Reconciler.new(entry, valuation_delta: -150).run

    assert_not manual_pledge.reload.status_matched?
  end


  # A buy moves money within an investment account, so it is not a deposit
  # and never resolves a transfer pledge.
  test "an imported buy on a goal-linked investment account leaves its transfer pledge open" do
    investment = accounts(:investment)
    pledge = open_transfer_pledge(investment, amount: 200)
    trade = investment.entries.create!(
      name: "Buy", date: Date.current, amount: -200, currency: "USD",
      entryable: Trade.new(qty: 1, price: 200, security: securities(:aapl), currency: "USD", investment_activity_label: "Buy")
    )

    GoalPledge::Reconciler.new(trade).run

    assert_equal "open", pledge.reload.status
  end

  # A self-custody wallet books coins arriving at its address as a transfer-in
  # trade with no cash side, so that trade is the deposit a transfer pledge
  # waits for.
  test "coins transferred into a goal-linked crypto account resolve its transfer pledge" do
    crypto = accounts(:crypto)
    pledge = open_transfer_pledge(crypto, amount: 200)
    entry = create_coin_transfer(crypto, qty: BigDecimal("0.004"), price: 50_000)

    GoalPledge::Reconciler.new(entry).run

    assert_equal "matched", pledge.reload.status
    assert_nil pledge.matched_transaction_id
    assert_equal pledge.id, entry.trade.reload.extra.dig("goal", "pledge_id")
  end

  # Every wallet sync re-imports every movement, so the trade that paid one
  # pledge must not pay the next one as well.
  test "a coin transfer that resolved one pledge does not resolve another" do
    crypto = accounts(:crypto)
    first = open_transfer_pledge(crypto, amount: 200)
    entry = create_coin_transfer(crypto, qty: BigDecimal("0.004"), price: 50_000)
    GoalPledge::Reconciler.new(entry).run
    assert_equal "matched", first.reload.status, "precondition"

    second = GoalPledge.create!(goal: first.goal, account: crypto, amount: 200, currency: "USD", kind: "transfer",
                                status: "open", expires_at: 7.days.from_now)
    GoalPledge::Reconciler.new(entry).run

    assert_equal "open", second.reload.status
    assert_equal first.id, entry.trade.reload.extra.dig("goal", "pledge_id")
  end

  test "coins transferred out of a crypto account leave its transfer pledge open" do
    crypto = accounts(:crypto)
    pledge = open_transfer_pledge(crypto, amount: 200)
    entry = create_coin_transfer(crypto, qty: BigDecimal("-0.004"), price: 50_000)

    GoalPledge::Reconciler.new(entry).run

    assert_equal "open", pledge.reload.status
  end

  # An exchange buy swaps cash already in the account for coins: no money
  # arrives, whatever the trade is worth.
  test "a buy on a crypto account leaves its transfer pledge open" do
    crypto = accounts(:crypto)
    pledge = open_transfer_pledge(crypto, amount: 200)
    entry = create_coin_transfer(crypto, qty: BigDecimal("0.004"), price: 50_000, label: "Buy", amount: 200)

    GoalPledge::Reconciler.new(entry).run

    assert_equal "open", pledge.reload.status
  end

  # Deposits into an investment account arrive as cash transactions, which
  # already resolve pledges; a transfer-in trade there moves securities.
  test "a transfer-in trade on an investment account leaves its transfer pledge open" do
    investment = accounts(:investment)
    pledge = open_transfer_pledge(investment, amount: 200)
    entry = create_coin_transfer(investment, qty: 1, price: 200, security: securities(:aapl))

    GoalPledge::Reconciler.new(entry).run

    assert_equal "open", pledge.reload.status
  end

  private
    def create_coin_transfer(account, qty:, price:, label: Trade::TRANSFER_LABEL, amount: 0, security: nil)
      security ||= Security.find_or_create_by!(ticker: "CRYPTO:BTC") { |s| s.name = "Bitcoin" }
      account.entries.create!(
        name: "Transfer", date: Date.current, amount: amount, currency: "USD",
        entryable: Trade.new(qty: qty, price: price, security: security, currency: "USD", investment_activity_label: label)
      )
    end

    def create_transaction_entry(amount:, date:, account: @account, excluded: false)
      Entry.create!(
        account: account,
        name: "Test",
        amount: BigDecimal(amount.to_s),
        currency: "USD",
        date: date,
        excluded: excluded,
        entryable: Transaction.new(kind: "standard")
      )
    end

    def create_valuation_entry(amount:, date:, account: @account)
      Entry.create!(
        account: account,
        name: "Manual balance",
        amount: BigDecimal(amount.to_s),
        currency: "USD",
        date: date,
        entryable: Valuation.new(kind: "reconciliation")
      )
    end
end
