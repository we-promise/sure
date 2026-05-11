require "test_helper"

class GoalContributionTest < ActiveSupport::TestCase
  setup do
    @goal = goals(:vacation_italy)
    @depository = accounts(:depository)
  end

  test "valid fixture contribution saves" do
    assert goal_contributions(:vacation_italy_initial).valid?
  end

  test "amount must be positive" do
    c = @goal.goal_contributions.new(account: @depository, amount: 0, currency: "USD", source: "manual", contributed_at: Date.current)
    assert_not c.valid?
  end

  test "source must be manual or initial" do
    c = @goal.goal_contributions.new(account: @depository, amount: 10, currency: "USD", source: "auto", contributed_at: Date.current)
    assert_not c.valid?
  end

  test "currency syncs from goal when blank" do
    c = @goal.goal_contributions.new(account: @depository, amount: 10, source: "manual", contributed_at: Date.current)
    c.valid?
    assert_equal @goal.currency, c.currency
  end

  test "account must be linked to goal" do
    other_depository = Account.create!(
      family: @goal.family,
      accountable: Depository.new,
      name: "Unlinked Depository",
      currency: "USD",
      balance: 100
    )
    c = @goal.goal_contributions.new(account: other_depository, amount: 10, currency: "USD", source: "manual", contributed_at: Date.current)
    assert_not c.valid?
    assert_includes c.errors[:account], "Account must be one of the goal's linked accounts."
  end

  test "manual? and initial? predicates" do
    assert goal_contributions(:vacation_italy_initial).initial?
    assert goal_contributions(:vacation_italy_manual).manual?
  end
end
