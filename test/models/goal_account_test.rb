require "test_helper"

class GoalAccountTest < ActiveSupport::TestCase
  setup do
    @goal = goals(:emergency_fund)
    @account = Account.create!(
      family: families(:dylan_family),
      accountable: Depository.new,
      name: "Allocation Test",
      currency: "USD",
      balance: 1_000
    )
  end

  test "allocated_amount may be nil, meaning dedicate the whole balance" do
    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: nil)
    assert ga.valid?, ga.errors.full_messages.to_sentence
    assert ga.whole_account?
  end

  test "a set allocated_amount is not a whole-account link" do
    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: 250)
    assert ga.valid?, ga.errors.full_messages.to_sentence
    assert_not ga.whole_account?
  end

  test "allocated_amount must be non-negative" do
    ga = GoalAccount.new(goal: @goal, account: @account, allocated_amount: -1)
    assert_not ga.valid?
    assert_includes ga.errors[:allocated_amount], "must be greater than or equal to 0"
  end
end
