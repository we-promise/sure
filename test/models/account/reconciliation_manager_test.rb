require "test_helper"

class Account::ReconciliationManagerTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @account = accounts(:investment)
    @manager = Account::ReconciliationManager.new(@account)
  end

  test "new reconciliation" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    result = @manager.reconcile_balance(balance: 1200, date: Date.current)

    assert_equal 1200, result.new_balance
    assert_equal 700, result.new_cash_balance # Non cash stays the same since user is valuing the entire account balance
    assert_equal 1000, result.old_balance
    assert_equal 500, result.old_cash_balance
    assert_equal true, result.success?
  end

  test "updates existing reconciliation without date change" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    # Existing reconciliation entry
    existing_entry = @account.entries.create!(name: "Test", amount: 1000, date: Date.current, entryable: Valuation.new(kind: "reconciliation"), currency: @account.currency)

    result = @manager.reconcile_balance(balance: 1200, date: Date.current, existing_valuation_entry: existing_entry)

    assert_equal 1200, result.new_balance
    assert_equal 700, result.new_cash_balance # Non cash stays the same since user is valuing the entire account balance
    assert_equal 1000, result.old_balance
    assert_equal 500, result.old_cash_balance
    assert_equal true, result.success?
  end

  test "updates existing reconciliation with date and amount change" do
    create_balance(account: @account, date: 5.days.ago, balance: 1000, cash_balance: 500)
    create_balance(account: @account, date: Date.current, balance: 1200, cash_balance: 700)

    # Existing reconciliation entry (5 days ago)
    existing_entry = @account.entries.create!(name: "Test", amount: 1000, date: 5.days.ago, entryable: Valuation.new(kind: "reconciliation"), currency: @account.currency)

    # Should update and change date for existing entry; not create a new one
    assert_no_difference "Valuation.count" do
      # "Update valuation from 5 days ago to today, set balance from 1000 to 1500"
      result = @manager.reconcile_balance(balance: 1500, date: Date.current, existing_valuation_entry: existing_entry)

      assert_equal true, result.success?

      # Reconciliation
      assert_equal 1500, result.new_balance # Equal to new valuation amount
      assert_equal 1000, result.new_cash_balance # Get non-cash balance today (1200 - 700 = 500). Then subtract this from new valuation (1500 - 500 = 1000)

      # Prior valuation
      assert_equal 1000, result.old_balance # This is the balance from the old valuation, NOT the date we're reconciling to
      assert_equal 500, result.old_cash_balance
    end
  end

  test "handles date conflicts" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 1000)

    # Existing reconciliation entry
    @account.entries.create!(
      name: "Test",
      amount: 1000,
      date: Date.current,
      entryable: Valuation.new(kind: "reconciliation"),
      currency: @account.currency
    )

    # Doesn't pass existing_valuation_entry, but reconciliation manager should recognize its the same date and update the existing entry
    assert_no_difference "Valuation.count" do
      result = @manager.reconcile_balance(balance: 1200, date: Date.current)

      assert result.success?
      assert_equal 1200, result.new_balance
    end
  end

  test "dry run does not persist account" do
    create_balance(account: @account, date: Date.current, balance: 1000, cash_balance: 500)

    assert_no_difference "Valuation.count" do
      @manager.reconcile_balance(balance: 1200, date: Date.current, dry_run: true)
    end

    assert_difference "Valuation.count", 1 do
      @manager.reconcile_balance(balance: 1200, date: Date.current)
    end
  end

  test "reconciliation matches an open manual_save pledge by contribution delta" do
    account = accounts(:depository)
    manager = Account::ReconciliationManager.new(account)
    create_balance(account: account, date: Date.current, balance: 2000, cash_balance: 2000)

    pledge = goal_pledges(:open_transfer).goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    result = manager.reconcile_balance(balance: 2150, date: Date.current)

    assert result.success?
    assert pledge.reload.status_matched?
  end

  test "reconciliation to the same balance leaves manual_save pledges open" do
    account = accounts(:depository)
    manager = Account::ReconciliationManager.new(account)
    create_balance(account: account, date: Date.current, balance: 2000, cash_balance: 2000)

    pledge = goal_pledges(:open_transfer).goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    result = manager.reconcile_balance(balance: 2000, date: Date.current)

    assert result.success?
    assert_not pledge.reload.status_matched?
  end

  test "second same-day reconcile derives its delta from the valuation it updates, not the stale balance row" do
    account = accounts(:depository)
    manager = Account::ReconciliationManager.new(account)
    create_balance(account: account, date: Date.current, balance: 2000, cash_balance: 2000)

    goal = goal_pledges(:open_transfer).goal
    first_pledge = goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    assert manager.reconcile_balance(balance: 2150, date: Date.current).success?
    assert first_pledge.reload.status_matched?

    # The post-reconcile balance sync is async and hasn't run, so the
    # balances row still says $2,000. The second save of $150 (2150 → 2300)
    # must not be read as a $300 contribution off that stale row — that
    # would wrongly close the larger pledge, and a wrong match never
    # self-heals.
    oversized_pledge = goal.goal_pledges.create!(
      account: account,
      amount: 300,
      currency: "USD",
      kind: "manual_save"
    )
    second_pledge = goal.goal_pledges.create!(
      account: account,
      amount: 150,
      currency: "USD",
      kind: "manual_save"
    )

    assert manager.reconcile_balance(balance: 2300, date: Date.current).success?

    assert_not oversized_pledge.reload.status_matched?
    assert second_pledge.reload.status_matched?
  end
end
