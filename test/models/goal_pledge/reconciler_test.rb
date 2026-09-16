require "test_helper"

class GoalPledge::ReconcilerTest < ActiveSupport::TestCase
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

  private
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
