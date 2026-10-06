require "test_helper"

# The Overview tab captures one reference date and every date-sensitive figure
# on it -- the repayment card's current instalment included -- answers for it.
class LoanOverviewViewTest < ActionView::TestCase
  helper AccountsHelper, LoansHelper

  setup do
    @account = Account.create!(
      family: families(:dylan_family),
      name: "Overview Loan",
      balance: 12_000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "auto", interest_rate: 0, term_months: 12,
        rate_type: "fixed", start_date: Date.new(2026, 1, 15)
      )
    )
  end

  test "the current instalment is the one for the page's date, not the clock's" do
    travel_to Date.new(2026, 9, 28) do
      render partial: "loans/tabs/overview", locals: { account: @account, as_of: Date.new(2026, 4, 20) }
    end

    assert_includes rendered, "Payment 4 ·", "the instalment on the page's date"
    assert_not_includes rendered, "Payment 9 ·", "not the one the clock is on"
  end
end
