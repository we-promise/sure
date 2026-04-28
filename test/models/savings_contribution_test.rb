require "test_helper"

class SavingsContributionTest < ActiveSupport::TestCase
  setup do
    @goal = savings_goals(:vacation)
  end

  test "valid fixture" do
    assert savings_contributions(:vacation_initial).valid?
  end

  test "requires source from SOURCES allowlist" do
    contribution = SavingsContribution.new(
      savings_goal: @goal, amount: 50, currency: "USD",
      source: "bogus", contributed_at: Date.current
    )
    assert_not contribution.valid?
    assert_includes contribution.errors.attribute_names, :source
  end

  test "auto source requires budget" do
    contribution = SavingsContribution.new(
      savings_goal: @goal, amount: 50, currency: "USD",
      source: "auto", contributed_at: Date.current
    )
    assert_not contribution.valid?
    assert_includes contribution.errors.attribute_names, :budget
  end

  test "auto source with budget is valid" do
    contribution = SavingsContribution.new(
      savings_goal: @goal,
      budget: budgets(:one),
      amount: 50, currency: "USD",
      source: "auto", contributed_at: Date.current
    )
    assert contribution.valid?
  end

  test "manual / initial sources do not require budget" do
    %w[manual initial].each do |source|
      contribution = SavingsContribution.new(
        savings_goal: @goal, amount: 50, currency: "USD",
        source: source, contributed_at: Date.current
      )
      assert contribution.valid?, "expected #{source} to be valid without budget"
    end
  end

  test "syncs currency from goal.account on save" do
    contribution = SavingsContribution.create!(
      savings_goal: @goal, amount: 50,
      source: "manual", contributed_at: Date.current
    )
    assert_equal @goal.account.currency, contribution.currency
  end

  test "syncs currency on subsequent updates" do
    contribution = savings_contributions(:vacation_initial)
    contribution.update!(currency: "EUR")
    contribution.save!
    assert_equal contribution.savings_goal.account.currency, contribution.reload.currency
  end

  test "scopes filter by source" do
    assert_equal 2, @goal.savings_contributions.count
    assert_equal 1, @goal.savings_contributions.initial.count
    assert_equal 1, @goal.savings_contributions.manual.count
    assert_equal 0, @goal.savings_contributions.auto.count
  end

  test "destroying a budget cascades to its auto contributions" do
    budget = budgets(:one)
    contribution = SavingsContribution.create!(
      savings_goal: @goal, budget: budget, amount: 50,
      currency: "USD", source: "auto", contributed_at: Date.current
    )
    budget.destroy
    assert_raises(ActiveRecord::RecordNotFound) { contribution.reload }
  end

  test "destroying a family with auto contributions does not raise FK errors" do
    # Build an isolated family so we sidestep the dylan_family fixture's
    # Plaid items (whose teardown hits external APIs in some envs). What
    # we care about is the FK between savings_contributions and budgets.
    family = Family.create!(name: "Throwaway", locale: "en", date_format: "%Y-%m-%d", currency: "USD")
    account = family.accounts.create!(
      name: "Pot", balance: 100, currency: "USD", accountable: Depository.new
    )
    goal = family.savings_goals.create!(
      account: account, name: "G", target_amount: 100,
      target_date: 6.months.from_now.to_date, state: "active"
    )
    budget = family.budgets.create!(
      start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month,
      currency: "USD"
    )
    SavingsContribution.create!(
      savings_goal: goal, budget: budget, amount: 10,
      currency: "USD", source: "auto", contributed_at: Date.current
    )
    assert_nothing_raised { family.destroy }
  end
end
