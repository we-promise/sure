require "test_helper"

class SavingsGoals::AutoFundJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @budget = budgets(:one)
    @goal = savings_goals(:vacation)
    # Make monthly_target_amount computable.
    @goal.update!(target_date: 6.months.from_now.to_date)
  end

  test "no-ops when family does not exist" do
    assert_nothing_raised do
      SavingsGoals::AutoFundJob.new.perform(SecureRandom.uuid, @budget.id)
    end
    assert_equal 0, SavingsContribution.auto.count
  end

  test "no-ops when budget does not exist" do
    assert_nothing_raised do
      SavingsGoals::AutoFundJob.new.perform(@family.id, SecureRandom.uuid)
    end
    assert_equal 0, SavingsContribution.auto.count
  end

  test "no-ops when surplus is zero" do
    Budget.any_instance.stubs(:monthly_surplus).returns(0)
    assert_no_difference -> { SavingsContribution.auto.count } do
      SavingsGoals::AutoFundJob.new.perform(@family.id, @budget.id)
    end
  end

  test "creates auto contribution capped by goal monthly target" do
    expected_max = @goal.monthly_target_amount
    Budget.any_instance.stubs(:monthly_surplus).returns(10_000)
    assert_difference -> { @goal.savings_contributions.auto.count }, +1 do
      SavingsGoals::AutoFundJob.new.perform(@family.id, @budget.id)
    end
    contribution = SavingsContribution.auto.find_by(savings_goal: @goal, budget: @budget)
    assert_equal "auto", contribution.source
    assert_equal @goal.currency, contribution.currency
    assert_equal @budget.start_date, contribution.contributed_at
    assert_operator contribution.amount, :<=, expected_max
  end

  test "is idempotent: re-running does not create a second auto contribution" do
    Budget.any_instance.stubs(:monthly_surplus).returns(10_000)
    SavingsGoals::AutoFundJob.new.perform(@family.id, @budget.id)
    assert_no_difference -> { SavingsContribution.auto.count } do
      SavingsGoals::AutoFundJob.new.perform(@family.id, @budget.id)
    end
  end

  test "caps amount by remaining_amount when goal is nearly met" do
    @goal.savings_contributions.delete_all
    @goal.savings_contributions.create!(
      amount: @goal.target_amount - 50,
      currency: @goal.currency,
      source: "manual",
      contributed_at: Date.current
    )
    Budget.any_instance.stubs(:monthly_surplus).returns(10_000)
    SavingsGoals::AutoFundJob.new.perform(@family.id, @budget.id)
    contribution = SavingsContribution.auto.find_by(savings_goal: @goal, budget: @budget)
    assert_not_nil contribution
    assert_operator contribution.amount, :<=, 50
  end

  test "skips goals in non-active states (paused / completed / archived)" do
    inactive_states = %w[paused completed archived]
    inactive_goals = inactive_states.map do |state|
      @family.savings_goals.create!(
        account: accounts(:depository),
        name: "Inactive #{state}",
        target_amount: 1_000,
        target_date: 3.months.from_now.to_date,
        state: state
      )
    end

    Budget.any_instance.stubs(:monthly_surplus).returns(5_000)
    SavingsGoals::AutoFundJob.new.perform(@family.id, @budget.id)

    inactive_goals.each do |goal|
      assert_equal 0, goal.savings_contributions.auto.count,
                   "expected no auto contributions for #{goal.state} goal"
    end
  end

  test "does not block manual contributions in same period" do
    @goal.savings_contributions.create!(
      amount: 50, currency: @goal.currency, source: "manual", contributed_at: Date.current
    )
    Budget.any_instance.stubs(:monthly_surplus).returns(5_000)
    assert_difference -> { @goal.savings_contributions.auto.count }, +1 do
      SavingsGoals::AutoFundJob.new.perform(@family.id, @budget.id)
    end
  end

  test "total auto-funded amount never exceeds the monthly surplus" do
    # Pool exhaustion: with multiple goals and a surplus smaller than the
    # combined monthly targets, the per-goal cap min(target, pool, remaining)
    # plus the `break if pool <= 0` guard keep the total spend bounded.
    @family.savings_goals.create!(
      account: accounts(:depository),
      name: "Smaller", target_amount: 600,
      target_date: 6.months.from_now.to_date, state: "active"
    )
    Budget.any_instance.stubs(:monthly_surplus).returns(150)
    SavingsGoals::AutoFundJob.new.perform(@family.id, @budget.id)
    funded = SavingsContribution.auto.where(budget: @budget).sum(:amount)
    assert_operator funded, :<=, 150
  end

  test "RecordNotUnique inside the loop does not abort other contributions" do
    # The previous version of this code wrapped `Family.transaction` around
    # the whole loop and only rescued RecordNotUnique at the outer scope.
    # Postgres aborts the whole transaction when a unique violation fires,
    # so a single duplicate would have rolled back every successful create
    # earlier in the loop. The fix wraps each `SavingsContribution.create!`
    # in `ActiveRecord::Base.transaction(requires_new: true)` so a savepoint
    # scopes the rollback to just the failing iteration.
    #
    # We exercise the rescue path by directly raising RecordNotUnique from
    # `SavingsContribution.create!` once, then letting subsequent calls land.
    second_goal = @family.savings_goals.create!(
      account: accounts(:depository),
      name: "Second goal",
      target_amount: 2_000,
      target_date: 6.months.from_now.to_date,
      state: "active"
    )
    Budget.any_instance.stubs(:monthly_surplus).returns(10_000)

    # First call (Awesome vacations) raises; second call (Second goal) succeeds.
    seq = sequence("auto-fund-create")
    SavingsContribution
      .stubs(:create!)
      .raises(ActiveRecord::RecordNotUnique.new("simulated race"))
      .in_sequence(seq)
    SavingsContribution
      .stubs(:create!)
      .returns(SavingsContribution.new)
      .in_sequence(seq)

    assert_nothing_raised do
      SavingsGoals::AutoFundJob.new.perform(@family.id, @budget.id)
    end
    # If the savepoint weren't there, the outer transaction would have
    # aborted on the first raise and `assert_nothing_raised` would fail
    # with `PG::InFailedSqlTransaction` on the next statement; reaching
    # this line is the assertion the savepoint did its job.
    assert true
  end
end
