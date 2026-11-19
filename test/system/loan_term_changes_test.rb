require "application_system_test_case"

class LoanTermChangesTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:loan)
    @account.loan.update!(
      subtype: "mortgage", rate_type: "fixed", interest_rate: 5.25, term_months: 360,
      start_date: 3.years.ago.to_date, initial_balance: 500_000
    )
    @account.entries.create!(
      name: "Drawdown", date: 3.years.ago.to_date, amount: 500_000, currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )
  end

  # The rows are added and removed by a Stimulus controller, which a request
  # test cannot run.
  test "a term change added in the form shows on the schedule" do
    visit account_url(@account)
    click_on "Overview"
    click_on "Edit loan details"

    find("summary", text: "Term changes").click
    assert_text "No term changes recorded"
    click_button "Add term change"
    assert_no_text "No term changes recorded"

    within "[data-term-change-row]" do
      find("input[type='date']").set(1.year.ago.to_date)
      find("input[name$='[extra_repayment]']").set("20000")
    end
    click_button "Update Account"

    assert_loan_saved
    assert_equal [ BigDecimal("20000") ], @account.loan.reload.term_changes.map(&:extra_repayment)

    visit account_url(@account, tab: "schedule")
    assert_text "Term change: -$20,000.00"
  end

  test "a term change removed in the form is deleted" do
    @account.loan.update!(term_change_rows: [ { effective_date: 1.year.ago.to_date.iso8601, payment: "2500" } ])

    visit account_url(@account)
    click_on "Overview"
    click_on "Edit loan details"

    find("summary", text: "Term changes").click
    within "[data-term-change-row]" do
      click_button "Remove"
    end
    assert_text "No term changes recorded"
    click_button "Update Account"

    assert_loan_saved
    assert_empty @account.loan.reload.term_changes
  end

  private
    # The account page refreshes itself shortly after it loads, which can take
    # the flash message with it. The edit dialog closing is the lasting sign
    # that the loan was saved; a refused save keeps the dialog open.
    def assert_loan_saved
      assert_no_selector "dialog[open]"
    end
end
