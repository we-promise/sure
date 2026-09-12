require "test_helper"

# The stamp a consumption leaves on a transaction must not outlive the goal
# state that wrote it.
class GoalConsumptionStampLifecycleTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "destroying a goal unstamps every transaction it consumed" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 800, 1.day.ago)
    goal.consume!(800, transaction: entry.entryable)

    goal.destroy!

    assert_equal({}, entry.entryable.reload.extra)
  end

  # An account can be unlinked from the goal after a consumption stamped a
  # transaction on it, so the sweep cannot rely on `linked_accounts`.
  test "destroying a goal unstamps even a transaction on an account since unlinked" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 800, 1.day.ago)
    goal.consume!(800, transaction: entry.entryable)
    goal.goal_accounts.destroy_all

    goal.destroy!

    assert_equal({}, entry.entryable.reload.extra)
  end

  test "reopening a completed goal unstamps what it consumed" do
    account = fresh_account(5_000)
    goal = goal_on(account, earmark: 5_000, target: 5_000, name: "Trip")
    entry = spend(account, 800, 1.day.ago)
    goal.consume!(800, transaction: entry.entryable)
    goal.update!(consumed_amount: goal.target_amount)
    goal.complete!

    goal.reopen!

    assert_equal BigDecimal("0"), goal.reload.consumed_amount
    assert_nil entry.entryable.reload.extra.dig("goal", "consumed_goal_id")
  end

  # Without unstamping, this transaction could never be attributed again to
  # ANY goal: stamp_consumption! refuses the SAME goal reclaiming one it
  # already holds, not only a different one.
  test "a spend from a previous cycle can be attributed again after reopening" do
    account = fresh_account(5_000)
    goal = goal_on(account, earmark: 5_000, target: 5_000, name: "Trip")
    entry = spend(account, 800, 1.day.ago)
    goal.consume!(800, transaction: entry.entryable)
    goal.update!(consumed_amount: goal.target_amount)
    goal.complete!
    goal.reopen!

    assert_nothing_raised { goal.reload.consume!(800, transaction: entry.entryable.reload) }
  end

  # An archived goal never froze a figure, so unarchiving must NOT wipe
  # history nothing replaced.
  test "unarchiving straight from active leaves consumption and stamps alone" do
    goal, account = goal_with_account(balance: 5_000)
    entry = spend(account, 800, 1.day.ago)
    goal.consume!(800, transaction: entry.entryable)
    goal.archive!

    goal.unarchive!

    assert_equal BigDecimal("800"), goal.reload.consumed_amount
    assert_equal goal.id, entry.entryable.reload.extra.dig("goal", "consumed_goal_id")
  end

  private
    def fresh_account(balance)
      Account.create!(
        family: @family, accountable: Depository.new,
        name: "Pot #{SecureRandom.hex(4)}", currency: "USD", balance: balance
      )
    end

    def goal_on(account, earmark:, target:, name:)
      @family.goals.create!(name: name, target_amount: target, currency: "USD") do |g|
        g.goal_accounts.build(account: account, allocated_amount: earmark)
      end
    end

    def goal_with_account(balance:)
      account = fresh_account(balance)
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
