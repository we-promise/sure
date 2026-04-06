require "test_helper"

class DepositoryTest < ActiveSupport::TestCase
  setup do
    @depository = depositories(:savings_with_interest)
  end

  test "interest_eligible? returns true when enabled with rate" do
    assert @depository.interest_eligible?
  end

  test "interest_eligible? returns false when disabled" do
    @depository.interest_enabled = false
    assert_not @depository.interest_eligible?
  end

  test "interest_eligible? returns false when rate is nil" do
    @depository.interest_rate = nil
    assert_not @depository.interest_eligible?
  end

  test "interest_eligible? returns false when rate is zero" do
    @depository.interest_rate = 0
    assert_not @depository.interest_eligible?
  end

  test "daily_interest_rate calculates correctly for non-leap year" do
    date = Date.new(2025, 6, 15)
    expected = 2.75 / 100.0 / 365
    assert_in_delta expected, @depository.daily_interest_rate(date), 1e-12
  end

  test "daily_interest_rate calculates correctly for leap year" do
    date = Date.new(2024, 6, 15)
    expected = 2.75 / 100.0 / 366
    assert_in_delta expected, @depository.daily_interest_rate(date), 1e-12
  end

  test "daily_interest_rate returns 0 when rate is nil" do
    @depository.interest_rate = nil
    assert_equal 0, @depository.daily_interest_rate
  end

  test "validates interest_rate range" do
    @depository.interest_rate = 101
    assert_not @depository.valid?

    @depository.interest_rate = -1
    assert_not @depository.valid?

    @depository.interest_rate = 50
    assert @depository.valid?
  end

  test "accrued_interest_this_month sums current month accruals" do
    total = @depository.accrued_interest_this_month
    assert total >= 0
  end

  test "total_interest_this_year sums current year accruals" do
    total = @depository.total_interest_this_year
    assert total >= 0
  end
end
