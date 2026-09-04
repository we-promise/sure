require "test_helper"

class RefreshMaintainedGoalTargetsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "a reserve's target follows what the window actually cost" do
    goal = reserve(months: 6, target: 1_000)
    seed_monthly_spend(500)

    RefreshMaintainedGoalTargetsJob.perform_now

    assert_equal BigDecimal("3000"), goal.reload.target_amount.to_d
  end

  # A family with no spending history yet would compute a floor of zero,
  # which violates the target_amount > 0 constraint and would read as "your
  # reserve is complete". Keep the number the user has been saving against.
  test "a window with no spending leaves the target standing" do
    goal = reserve(months: 6, target: 1_000)
    seed_monthly_spend(0)

    RefreshMaintainedGoalTargetsJob.perform_now

    assert_equal BigDecimal("1000"), goal.reload.target_amount.to_d
  end

  test "fixed-target reserves and one-off goals are left alone" do
    fixed = reserve(months: nil, target: 2_000, mode: "fixed")
    one_off = @family.goals.create!(
      name: "Trip", target_amount: 800, currency: "USD"
    ) { |g| g.goal_accounts.build(account: account_for("Trip")) }
    seed_monthly_spend(500)

    RefreshMaintainedGoalTargetsJob.perform_now

    assert_equal BigDecimal("2000"), fixed.reload.target_amount.to_d
    assert_equal BigDecimal("800"), one_off.reload.target_amount.to_d
  end

  test "an archived reserve is not refreshed" do
    goal = reserve(months: 6, target: 1_000)
    goal.archive!
    seed_monthly_spend(500)

    RefreshMaintainedGoalTargetsJob.perform_now

    assert_equal BigDecimal("1000"), goal.reload.target_amount.to_d
  end

  test "a target already equal to the computed figure is not rewritten" do
    goal = reserve(months: 6, target: 3_000)
    seed_monthly_spend(500)

    assert_no_changes -> { goal.reload.updated_at } do
      RefreshMaintainedGoalTargetsJob.perform_now
    end
  end

  # A reserve silently frozen at a stale floor is invisible to the user, so
  # the failure belongs in the support UI, not only in the application log.
  test "a write that fails validation is recorded for support" do
    goal = reserve(months: 6, target: 1_000)
    seed_monthly_spend(500)
    Goal.any_instance.stubs(:update!).raises(
      ActiveRecord::RecordInvalid.new(goal)
    )

    assert_difference -> { DebugLogEntry.where(category: "goals").count }, 1 do
      RefreshMaintainedGoalTargetsJob.perform_now
    end

    assert_equal BigDecimal("1000"), goal.reload.target_amount.to_d
  end

  private
    def account_for(name)
      Account.create!(
        family: @family, accountable: Depository.new,
        name: "#{name} Pot", currency: "USD", balance: 1_000
      )
    end

    # `target` is the figure the reserve STARTS from, so it is written past
    # the before_save that computes a months-mode floor on creation — these
    # tests are about what the job does to an existing target, not about
    # where that target came from.
    def reserve(months:, target:, mode: "months_of_expenses", name: "Emergency")
      goal = @family.goals.create!(
        name: name, target_amount: target, currency: "USD",
        kind: "maintained", target_mode: mode, target_months: months
      ) { |g| g.goal_accounts.build(account: account_for(name)) }

      goal.update_column(:target_amount, target)
      goal.reload
    end

    # Real spending rather than a stub of the derivation: what the job exists to
    # do is re-read the window, and stubbing that out would leave these tests
    # asserting nothing about it. Twelve months so any window under test is
    # fully covered; zero means a family that has spent nothing.
    def seed_monthly_spend(amount)
      return if amount.to_d.zero?

      account = @family.accounts.create!(
        accountable: Depository.new, name: "Spending #{SecureRandom.hex(3)}",
        currency: "USD", balance: 0
      )
      12.times do |i|
        account.entries.create!(
          date: Date.current.prev_month.beginning_of_month - i.months + 5.days,
          name: "Living cost",
          amount: BigDecimal(amount.to_s),
          currency: "USD",
          entryable: Transaction.new
        )
      end
    end
end
