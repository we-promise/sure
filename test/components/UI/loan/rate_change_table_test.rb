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

  # cubic, #79. The projection's beginning_balance is the GROSS loan balance --
  # an offset reduces the interest charged, not the principal owed -- while
  # current_minimum_payment quotes net of offset. Reading one from each put two
  # bases in one row again and overstated every future repayment.
  test "an offset loan quotes the new repayment net of offset, like the current one" do
    offset = @family.accounts.create!(
      name: "Table Offset", balance: 50_000, currency: "USD", accountable: Depository.new
    )
    @loan.update!(offset_account_ids: [ offset.id ])
    @loan.reload.add_variable_rate_change(Date.current + 2.months, 5.93)

    row = UI::Loan::RateChangeTable.new(loan: @loan.reload).rows.sole

    assert_operator row[:balance].amount, :<, BigDecimal("360000"),
      "the projected balance must be net of the offset, as the current column is"
    assert_in_delta 47, (row[:current_payment] - row[:new_payment]).amount, 20,
      "both columns net of offset: a 0.25pp cut is a modest move, not a step change"
  end

  # A change effective ON a payment date uses that payment's opening balance,
  # so that payment must be counted among the periods it is spread over.
  # Counting only payments strictly after the date dropped exactly one.
  test "a change effective on a payment date is amortised over that payment too" do
    payment_date = @loan.payoff_projection.payments.map { |p| p[:payment_date] }[3]
    @loan.add_variable_rate_change(payment_date, 5.93)

    row = UI::Loan::RateChangeTable.new(loan: @loan.reload).rows.sole
    schedule = @loan.amortization_schedule
    inclusive = schedule.remaining_payment_count(as_of: payment_date, including_on_date: true)
    exclusive = schedule.remaining_payment_count(as_of: payment_date)

    assert_equal exclusive + 1, inclusive,
      "the fixture must actually put a payment on the effective date, or this test proves nothing"

    recomputed = Loan::AmortizationMath.level_payment(
      balance: row[:balance].amount,
      monthly_rate: Loan.monthly_rate(row[:new_rate]),
      remaining_payments: inclusive,
      currency_precision: 2
    )

    assert_equal recomputed, row[:new_payment].amount,
      "the boundary payment supplies the balance, so it must be counted among the periods"
  end

  test "a fixed-rate loan carrying leftover rate rows renders nothing" do
    @loan.add_variable_rate_change(Date.current + 2.months, 5.93)
    @loan.update!(rate_type: "fixed")

    component = UI::Loan::RateChangeTable.new(loan: @loan.reload)

    assert_empty component.rows,
      "rate rows kept as history on a fixed loan are not forthcoming changes"
    assert_not component.render?
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
