require "test_helper"

# The record of what a goal spent, and undoing it.
class GoalConsumptionHistoryTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  # --- consumed_entries ---

  test "consumed_entries lists what was attributed, newest first" do
    goal, account = goal_with_account(balance: 5_000)
    older = spend(account, 300, 5.days.ago)
    goal.consume!(300, transaction: older.entryable)
    newer = spend(account, 200, 1.day.ago)
    goal.consume!(200, transaction: newer.entryable)

    ids = goal.consumed_entries([ account.id ]).map(&:id)

    assert_equal [ newer.id, older.id ], ids
  end

  test "consumed_entries excludes a spend attributed to a different goal" do
    goal, account = goal_with_account(balance: 5_000)
    other_goal, other_account = goal_with_account(balance: 5_000)
    mine = spend(account, 300, 1.day.ago)
    goal.consume!(300, transaction: mine.entryable)
    theirs = spend(other_account, 300, 1.day.ago)
    other_goal.consume!(300, transaction: theirs.entryable)

    ids = goal.consumed_entries([ account.id ]).map(&:id)

    assert_equal [ mine.id ], ids
  end

  test "consumed_entries excludes an unattributed spend" do
    goal, account = goal_with_account(balance: 5_000)
    spend(account, 300, 1.day.ago)

    assert_empty goal.consumed_entries([ account.id ])
  end

  test "consumed_entries is empty for a blank account scope" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 300, 1.day.ago)
    goal.consume!(300, transaction: entry.entryable)

    assert_empty goal.consumed_entries([])
  end

  # --- consumption_unaccounted_for ---

  test "consumption_unaccounted_for is the gap a bare-amount consume! leaves" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 300, 1.day.ago)
    goal.consume!(300, transaction: entry.entryable)
    goal.consume!(150) # bare amount, no transaction — leaves no trace

    listed_total = goal.consumed_entries([ account.id ]).sum { |e| e.amount.to_d }

    assert_equal BigDecimal("150"), goal.consumption_unaccounted_for(listed_total)
  end

  test "consumption_unaccounted_for never goes negative" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 300, 1.day.ago)
    goal.consume!(300, transaction: entry.entryable)

    assert_equal BigDecimal("0"), goal.consumption_unaccounted_for(BigDecimal("300"))
  end

  # --- release_consumption! ---

  test "releasing takes the amount back off consumed_amount and unstamps" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 300, 1.day.ago)
    goal.consume!(300, transaction: entry.entryable)

    goal.release_consumption!(entry.entryable)

    assert_equal BigDecimal("0"), goal.reload.consumed_amount
    assert_nil entry.entryable.reload.extra.dig("goal", "consumed_goal_id")
  end

  test "releasing does not restore the account's earmark" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 300, 1.day.ago)
    goal.consume!(300, transaction: entry.entryable)
    shrunk = goal.reload.goal_accounts.first.allocated_amount.to_d

    goal.release_consumption!(entry.entryable)

    assert_equal shrunk, goal.reload.goal_accounts.first.allocated_amount.to_d
  end

  test "a released spend is offered by the detector again" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 300, 1.day.ago)
    goal.consume!(300, transaction: entry.entryable)
    assert_empty Goal::WithdrawalDetector.new(goal).unattributed_outflows

    goal.release_consumption!(entry.entryable)

    ids = Goal::WithdrawalDetector.new(goal).unattributed_outflows.map(&:id)
    assert_includes ids, entry.id
  end

  test "releasing a spend claimed by a different goal is refused" do
    goal, account = goal_with_account(balance: 5_000)
    other_goal, other_account = goal_with_account(balance: 5_000)
    entry = spend(other_account, 300, 1.day.ago)
    other_goal.consume!(300, transaction: entry.entryable)

    assert_raises(Goal::ConsumptionRefused) { goal.release_consumption!(entry.entryable) }
  end

  test "releasing an unattributed transaction is refused" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 300, 1.day.ago)

    assert_raises(Goal::ConsumptionRefused) { goal.release_consumption!(entry.entryable) }
  end

  # Defensive: `consumed_amount` and its stamps should never drift, but the
  # column carries a >= 0 check constraint, so this turns what would be a 500
  # into something the user can read if they ever do.
  test "releasing more than consumed_amount can cover is refused" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 300, 1.day.ago)
    goal.consume!(300, transaction: entry.entryable)
    goal.update_columns(consumed_amount: 100) # simulate drift

    error = assert_raises(Goal::ConsumptionRefused) { goal.release_consumption!(entry.entryable) }
    assert_equal :release_exceeds_consumed, error.reason
  end

  test "releasing on an inactive goal is refused" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 300, 1.day.ago)
    goal.consume!(300, transaction: entry.entryable)
    goal.update!(consumed_amount: goal.target_amount)
    goal.complete!

    assert_raises(Goal::ConsumptionRefused) { goal.release_consumption!(entry.entryable) }
  end

  private
    def goal_on(account, earmark:, target:, name:)
      @family.goals.create!(name: name, target_amount: target, currency: "USD") do |g|
        g.goal_accounts.build(account: account, allocated_amount: earmark)
      end
    end

    def goal_with_account(balance:)
      account = Account.create!(
        family: @family, accountable: Depository.new,
        name: "Pot #{SecureRandom.hex(4)}", currency: "USD", balance: balance
      )
      goal = goal_on(account, earmark: balance, target: balance, name: "Trip #{SecureRandom.hex(4)}")
      [ goal, account ]
    end

    def spend(account, amount, date)
      account.entries.create!(
        name: "Spend #{SecureRandom.hex(3)}", date: date, amount: amount,
        currency: account.currency, entryable: Transaction.new
      )
    end
end
