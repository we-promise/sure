require "test_helper"

class Goal::RetirementAdjustmentTest < ActiveSupport::TestCase
  setup do
    @adj = goal_retirement_adjustments(:mortgage_paid_off)
  end

  test "fixture is valid" do
    assert @adj.valid?, @adj.errors.full_messages.to_sentence
  end

  test "amount can be negative (a reduction)" do
    assert @adj.amount_today.negative?
    assert @adj.valid?
  end

  test "to_age must exceed from_age when present" do
    @adj.to_age = @adj.from_age - 1
    assert_not @adj.valid?
  end

  test "applicable_at? respects the from/to range" do
    assert_not @adj.applicable_at?(@adj.from_age - 1)
    assert @adj.applicable_at?(@adj.from_age)
    assert @adj.applicable_at?(@adj.from_age + 5) # to_age nil => forever
  end

  test "amount_today_money uses the adjustment currency" do
    assert_equal Money.new(-680, "USD"), @adj.amount_today_money
  end
end
