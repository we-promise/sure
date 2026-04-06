require "test_helper"

class InterestAccrualTest < ActiveSupport::TestCase
  setup do
    @depository = depositories(:savings_with_interest)
    @accrual = interest_accruals(:one)
  end

  test "validates required fields" do
    accrual = InterestAccrual.new
    assert_not accrual.valid?
    assert_includes accrual.errors[:date], "can't be blank"
    assert_includes accrual.errors[:balance_used], "can't be blank"
    assert_includes accrual.errors[:daily_rate], "can't be blank"
    assert_includes accrual.errors[:amount], "can't be blank"
  end

  test "validates uniqueness of date per depository" do
    duplicate = InterestAccrual.new(
      depository: @depository,
      date: @accrual.date,
      balance_used: 10000,
      daily_rate: 0.00007534,
      amount: 0.7534
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:date], "has already been taken"
  end

  test "unpaid scope returns only unpaid accruals" do
    @accrual.update!(paid_out: true)
    unpaid = @depository.interest_accruals.unpaid
    assert_not_includes unpaid, @accrual
  end

  test "for_month scope filters by month" do
    year = @accrual.date.year
    month = @accrual.date.month
    results = InterestAccrual.for_month(year, month)
    assert_includes results, @accrual
  end

  test "for_year scope filters by year" do
    year = @accrual.date.year
    results = InterestAccrual.for_year(year)
    assert_includes results, @accrual
  end
end
