require "test_helper"

class UI::Loan::RateChangeTableTest < ViewComponent::TestCase
  setup do
    @family = families(:dylan_family)
    @loan = variable_loan
  end

  test "renders one row per future rate change, in lender-letter shape" do
    @loan.add_variable_rate_change(Date.current + 2.months, 5.93)

    render_inline UI::Loan::RateChangeTable.new(loan: @loan)

    assert_selector "[data-rate-change-table] tr", count: 1
    assert_text I18n.t("UI.loan.rate_change_table.title")
  end

  # A change already in effect IS the current rate -- the card above this table
  # already states it, and repeating it as forthcoming would be wrong.
  test "a rate change already in effect is not listed as forthcoming" do
    @loan.add_variable_rate_change(Date.current - 2.months, 5.93)

    component = UI::Loan::RateChangeTable.new(loan: @loan)

    assert_empty component.rows
    assert_not component.render?
  end

  test "a variable loan with no scheduled changes renders nothing at all" do
    assert_not UI::Loan::RateChangeTable.new(loan: @loan).render?

    render_inline UI::Loan::RateChangeTable.new(loan: @loan)

    assert_no_text I18n.t("UI.loan.rate_change_table.title")
  end

  # Both columns must be computed on the same balance. Reading the "new"
  # balance off the CONTRACTED schedule while the "current" figure uses today's
  # actual balance made a rate cut appear to save several times what the rate
  # itself accounts for -- the difference was the principal changing between
  # the two columns, not the rate.
  test "the current and new repayments sit on the same projected balance" do
    @loan.add_variable_rate_change(Date.current + 2.months, 5.93)

    row = UI::Loan::RateChangeTable.new(loan: @loan).rows.sole

    assert_in_delta @loan.account.balance, row[:balance].amount, 2_000,
      "a projected balance far from today's actual balance means the columns disagree on principal"
    assert row[:new_payment] < row[:current_payment],
      "a rate cut must lower the quoted repayment"
    assert_in_delta 54, (row[:current_payment] - row[:new_payment]).amount, 15,
      "0.25pp off ~$400k over ~277 months is a ~$54/month move; a much larger gap means the principal moved too"
  end

  private

    def variable_loan
      @family.accounts.create!(
        name: "Rate Change Table Loan",
        balance: 400_762.12,
        currency: "USD",
        accountable: Loan.new(
          rate_type: "variable", interest_rate: 6.18, term_months: 360,
          initial_balance: 400_762.12, start_date: Date.current - 83.months
        )
      ).loan
    end
end
