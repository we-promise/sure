require "application_system_test_case"

class LoanOverviewTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:loan)
    @account.loan.update!(
      subtype: "mortgage", rate_type: "fixed", interest_rate: 5.25, term_months: 360,
      start_date: 3.years.ago.to_date, down_payment: 100_000,
      insurance_rate: 0.36, insurance_rate_type: "level_term"
    )
    @account.entries.create!(
      name: "Drawdown", date: 3.years.ago.to_date, amount: 500_000, currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
    @account.update_column(:balance, 415_000)
  end

  # The ring is the one part of this tab a request test cannot see. Its colours
  # are CSS variables, and the donut controller passes a colour through to the
  # SVG fill ONLY for the segment ids it is told to -- every other one goes
  # through `d3.color()`, which returns null for `var(...)` and takes the whole
  # chart down with it. The arc simply does not appear, and every server-side
  # assertion still passes.
  test "the repayment ring draws its arc" do
    visit account_url(@account)
    click_on "Overview"

    assert_text "Repaid"
    assert_text "17%"

    within "[data-controller='donut-chart']" do
      assert_selector "svg path", minimum: 1, wait: 5
    end
  end
end
