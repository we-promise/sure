require "application_system_test_case"

class LoanPayoffChartTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
  end

  test "loan account opens on the overview tab" do
    visit account_path(accounts(:loan))

    assert_selector "button[data-id='overview'][aria-selected='true']"
    assert_selector "h4", text: I18n.t("loans.tabs.overview.original_payoff_date")
  end

  # Browser-level regression: mounts the chart for a real loan whose payment
  # anchor doesn't fall on today's day-of-month and whose current balance is
  # *behind* the original schedule (balance grew, not shrank) -- the two
  # scenarios the production-readiness review specifically called out as
  # uncovered (mid-cycle dates, behind-schedule balance). Reads the payload
  # off the mounted controller's own data attribute rather than parsing
  # rendered SVG paths, which would be a brittle way to assert on data that
  # already has full model-level coverage (Loan::PayoffProjectionTest,
  # LoanTest#payoff_chart_payload) -- this test's job is only to prove the
  # correct payload actually reaches the browser and mounts the controller,
  # not to re-verify the underlying math.
  test "schedule tab mounts the payoff chart with the anchored dates for a mid-cycle, behind-schedule loan" do
    # Pinned: if this ran on the 15th of any month, start_date's day-15
    # anchor would coincide with Date.current.next_month, defeating the
    # "real anchor mismatch" guard below and the point of the regression.
    travel_to Date.new(2026, 3, 20) do
      start_date = 2.years.ago.to_date.change(day: 15)
      loan_account = Account.create! \
        family: @user.family,
        name: "Mid-Cycle Behind Loan",
        balance: 500000,
        currency: "USD",
        accountable: Loan.create!(
          subtype: "mortgage",
          interest_rate: 3.5,
          term_months: 360,
          rate_type: "fixed",
          start_date: start_date
        )
      loan_account.entries.create!(
        name: "Starting balance",
        amount: 500000,
        currency: "USD",
        date: start_date,
        entryable: Valuation.new(kind: "opening_anchor")
      )
      loan_account.update!(balance: 550000) # behind schedule: balance grew, not shrank
      loan_account.loan.ensure_amortization_schedule_current!

      next_scheduled_date = loan_account.loan.amortizations.where("payment_date > ?", Date.current).ordered.first.payment_date
      assert_not_equal Date.current.next_month, next_scheduled_date, "test setup should exercise a real anchor mismatch"

      projection = loan_account.loan.payoff_projection
      assert_not projection.months_saved.positive?, "test setup should exercise a behind-schedule projection"
      schedule = loan_account.loan.amortization_schedule

      visit account_path(loan_account, tab: "schedule")

      chart = find("[data-controller='loan-payoff-chart']")
      payload = JSON.parse(chart["data-loan-payoff-chart-data-value"])

      assert_equal false, payload["ahead"]
      assert_equal schedule.payoff_date.iso8601, payload["original_payoff_date"]
      assert_equal projection.payoff_date.iso8601, payload["accelerated_payoff_date"]
      assert_equal next_scheduled_date.iso8601, payload["original_projection"].first["date"]
    end
  end
end
