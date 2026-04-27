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

  test "skips paused / completed / archived goals" do
    paused = @family.savings_goals.create!(
      name: "Paused", target_amount: 1000, currency: "USD",
      state: "paused", target_date: 3.months.from_now.to_date
    )
    Budget.any_instance.stubs(:monthly_surplus).returns(5_000)
    SavingsGoals::AutoFundJob.new.perform(@family.id, @budget.id)
    assert_equal 0, paused.savings_contributions.auto.count
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

  test "competes goals fairly when surplus is limited and stops once exhausted" do
    @family.savings_goals.create!(
      name: "Smaller", target_amount: 600, currency: "USD",
      target_date: 6.months.from_now.to_date, state: "active"
    )
    Budget.any_instance.stubs(:monthly_surplus).returns(150)
    SavingsGoals::AutoFundJob.new.perform(@family.id, @budget.id)
    funded = SavingsContribution.auto.where(budget: @budget).sum(:amount)
    assert_operator funded, :<=, 150
  end
end
