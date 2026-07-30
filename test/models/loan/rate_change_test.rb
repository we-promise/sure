require "test_helper"

class Loan::RateChangeTest < ActiveSupport::TestCase
  test "requires an effective date and a non-negative rate" do
    change = Loan::RateChange.new

    assert_not change.valid?
    assert_includes change.errors[:effective_date], "can't be blank"
    assert_includes change.errors[:rate], "can't be blank"

    change.rate = -1
    assert_not change.valid?
    assert_includes change.errors[:rate], "must be greater than or equal to 0"
  end

  test "forbids two changes on the same date for one loan" do
    loan = accrual_loan
    loan.rate_changes.create!(effective_date: Date.new(2026, 6, 1), rate: 9)

    duplicate = loan.rate_changes.build(effective_date: Date.new(2026, 6, 1), rate: 12)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:effective_date], "has already been taken"
  end

  private
    def accrual_loan
      Account.create!(
        family: families(:dylan_family),
        name: "Accrual Mortgage",
        balance: 200_000,
        currency: "USD",
        accountable: Loan.new(
          accrue_interest: true,
          interest_rate: 6,
          interest_accrual_start_date: Date.new(2026, 1, 1),
          rate_type: "variable"
        )
      ).loan
    end
end
