# Builds a manual, opted-in loan account ready for interest accrual. Shared by
# the loan model tests so the base fixture lives in one place.
module AccrualLoanHelper
  def accrual_loan(**overrides)
    attributes = {
      accrue_interest: true,
      interest_rate: 6,
      interest_accrual_start_date: Date.new(2026, 1, 1),
      rate_type: "fixed"
    }.merge(overrides)

    Account.create!(
      family: families(:dylan_family),
      name: "Accrual Mortgage",
      balance: 200_000,
      currency: "USD",
      accountable: Loan.new(**attributes)
    ).loan
  end
end
