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

  test "switching back to fixed retains both payment amounts" do
    @account.loan.update!(contracted_payment: 2_500, balloon_payment: 50_000)
    visit account_path(@account)
    find("a[href='#{edit_account_path(@account)}']", visible: :all).execute_script("this.click()")

    within "dialog[open]" do
      amounts = "[data-loan-rate-changes-target='fixedOnly']"
      rate_type = find("[data-loan-rate-changes-target='rateType']")
      rate_type.find("option[value='variable']").select_option
      assert_no_selector amounts
      assert_equal [ "", "" ], page.evaluate_script(<<~'JS')
        Array.from(new FormData(document.querySelector("dialog[open] form")))
          .filter(([key]) => /\[(contracted_payment|balloon_payment)\]$/.test(key))
          .map(([, value]) => value)
      JS

      rate_type.find("option[value='fixed']").select_option
      within amounts do
        assert_field I18n.t("loans.form.contracted_payment"), with: "2500.00"
        assert_field I18n.t("loans.form.balloon_payment"), with: "50000.00"
      end
    end
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
