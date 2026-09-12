require "test_helper"

# The behaviour #104 exists for: a schedule that re-amortises at each recorded
# rate change, and does so on the right dates.
class Loan::VariableRateScheduleTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "a fixed loan is unaffected by this feature" do
    fixed = build_loan(rate_type: "fixed")

    # 500,000 at 6% over 360 months.
    assert_equal BigDecimal("2997.75"), fixed.amortization_schedule.periodic_payment.amount
    assert_equal 360, fixed.amortization_schedule.payments.count
    assert_not fixed.amortization_schedule.re_amortising?
  end

  test "a variable loan with no recorded changes runs at its base rate" do
    variable = build_loan(rate_type: "variable")
    fixed = build_loan(rate_type: "fixed")

    assert_not variable.amortization_schedule.re_amortising?
    assert_equal fixed.amortization_schedule.total_interest,
      variable.amortization_schedule.total_interest,
      "a variable loan with no changes recorded is running at its base rate, and must cost the same"
  end

  test "a recorded rate change resizes the repayment from its effective date" do
    loan = build_loan(
      rate_type: "variable", term_months: 24, start_date: Date.new(2026, 1, 1),
      variable_rate_schedule: { "2026-07-01" => "18.0" }
    )
    payments = loan.amortization_schedule.payments

    before = payments.find { |p| p.date == Date.new(2026, 6, 1) }
    on_change = payments.find { |p| p.date == Date.new(2026, 7, 1) }

    assert loan.amortization_schedule.re_amortising?
    assert_operator on_change.payment.amount, :>, before.payment.amount
  end

  # C10. Accrual windows are half-open: a rate effective 1 July belongs to
  # [Jul 1, Aug 1), not to the June that ran entirely at the old rate. Reading
  # one rate for both accrual and payment sizing bills the month ENDING on the
  # boundary at a rate that applied for none of it.
  test "a rate change landing on a payment date does not re-rate the month before it" do
    loan = build_loan(
      rate_type: "variable", term_months: 24, start_date: Date.new(2026, 1, 1),
      variable_rate_schedule: { "2026-07-01" => "18.0" }
    )
    payments = loan.amortization_schedule.payments
    closing_on_change = payments.find { |p| p.date == Date.new(2026, 7, 1) }

    # 6% on the balance the June->July window opened with, not 18%.
    expected = (closing_on_change.ending_balance.amount + closing_on_change.principal.amount) *
      BigDecimal("6") / 100 / 12

    assert_in_delta expected.to_f, closing_on_change.interest.amount.to_f, 0.01,
      "the month ending on the rate change must still be billed at the old rate"
  end

  # Regression for we-promise/sure#3296's second blocking finding. A segment
  # spanning a single 30-day month is `floor(30 / 30.44) == 0` payments under
  # average-month arithmetic, and was silently skipped. This engine counts real
  # payment dates, so the segment cannot vanish -- pinned end-to-end on the
  # money, because a skipped segment leaves a well-formed schedule and raises
  # nothing.
  test "a rate spike confined to a single 30-day month is charged, not skipped" do
    spiked = build_loan(
      rate_type: "variable", term_months: 24, start_date: Date.new(2026, 1, 1),
      variable_rate_schedule: { "2026-04-01" => "18.0", "2026-05-01" => "6.0" }
    )
    flat = build_loan(rate_type: "variable", term_months: 24, start_date: Date.new(2026, 1, 1))

    assert_equal 30, (Date.new(2026, 5, 1) - Date.new(2026, 4, 1)).to_i,
      "premise: the segment under test spans a 30-day month"

    assert_operator spiked.amortization_schedule.total_interest.amount,
      :>, flat.amortization_schedule.total_interest.amount,
      "a rate spike confined to one 30-day month must change the interest charged"
  end

  test "current_variable_rate reads the change in force, and the base rate before any" do
    loan = build_loan(
      rate_type: "variable",
      variable_rate_schedule: { "2026-04-01" => "18.0", "2026-07-01" => "9.5" }
    )

    assert_equal BigDecimal("6"), loan.current_variable_rate(Date.new(2026, 3, 31))
    assert_equal BigDecimal("18.0"), loan.current_variable_rate(Date.new(2026, 4, 1))
    assert_equal BigDecimal("18.0"), loan.current_variable_rate(Date.new(2026, 6, 30))
    assert_equal BigDecimal("9.5"), loan.current_variable_rate(Date.new(2026, 7, 1))
  end

  # One reader of the column. `RateResolver` used to re-parse what
  # `variable_rates` had already sorted by, so the two read paths returned
  # different types for the same rows, and a parsing fix could land in one
  # and not the other.
  test "variable_rates is the one parsed reading of the column, dated and decimal" do
    loan = build_loan(
      rate_type: "variable",
      variable_rate_schedule: { "2026-07-01" => "9.5", "2026-04-01" => "18.0" }
    )

    assert_equal [ [ Date.new(2026, 4, 1), BigDecimal("18.0") ], [ Date.new(2026, 7, 1), BigDecimal("9.5") ] ],
      loan.variable_rates
    assert_equal [ Date, BigDecimal ], loan.variable_rates.first.map(&:class)
    assert_equal [ { effective_date: "2026-04-01", rate: "18.0" }, { effective_date: "2026-07-01", rate: "9.5" } ],
      loan.rate_change_rows, "the form still renders what was stored"
  end

  test "a fixed loan ignores any rate changes recorded against it" do
    loan = build_loan(rate_type: "fixed", variable_rate_schedule: { "2026-04-01" => "18.0" })

    assert_equal BigDecimal("6"), loan.current_variable_rate(Date.new(2026, 12, 1))
    assert_not loan.amortization_schedule.re_amortising?
  end

  test "re-entering an effective date replaces that row rather than adding a second" do
    loan = build_loan(rate_type: "variable")

    loan.rate_changes = [
      { effective_date: "2026-04-01", rate: "7.5" },
      { effective_date: "2026-04-01", rate: "8.25" }
    ]

    assert_equal({ "2026-04-01" => "8.25" }, loan.variable_rate_schedule)
  end

  test "blank and unparseable rows are kept out of the schedule without raising" do
    loan = build_loan(rate_type: "variable")

    loan.rate_changes = [
      { effective_date: "", rate: "7.5" },
      { effective_date: "2026-04-01", rate: "" },
      { effective_date: "not a date", rate: "7.5" },
      { effective_date: "2026-05-01", rate: "7.5" }
    ]

    assert_equal({ "2026-05-01" => "7.5" }, loan.variable_rate_schedule)
  end

  # The earlier version of this test never created a valuation, so
  # `first_valuation` was nil and the first assertion compared the opening
  # anchor with itself -- it passed without exercising the branch it named.
  test "origination prefers a recorded start date over the account's first valuation" do
    loan = build_loan(rate_type: "fixed")
    loan.account.entries.create!(
      name: "Opening balance", amount: 500_000, currency: "USD",
      date: Date.new(2022, 6, 1), entryable: Valuation.new(kind: "opening_anchor")
    )
    loan.account.reload

    assert_equal Date.new(2022, 6, 1), loan.reload.origination_date,
      "with no start_date, origination is the account's first valuation"

    loan.update!(start_date: Date.new(2020, 3, 15))
    assert_equal Date.new(2020, 3, 15), loan.origination_date,
      "a recorded start_date outranks the first valuation"
  end


  # `periodic_payment` used to re-derive the annuity from the loan's base rate.
  # A change effective ON the first payment date already sizes that payment, so
  # the card quoted a rate for a payment the borrower will never make.
  test "the opening payment reflects a rate change effective on the first payment date" do
    start_date = Date.new(2026, 1, 1)
    first_payment = start_date >> 1

    base = build_loan(rate_type: "variable", term_months: 24, start_date: start_date)
    changed = build_loan(rate_type: "variable", term_months: 24, start_date: start_date,
                         variable_rate_schedule: { first_payment.iso8601 => "18.0" })

    assert_equal changed.amortization_schedule.payments.first.payment,
      changed.amortization_schedule.periodic_payment,
      "the quoted opening payment must be the payment actually scheduled"
    assert_operator changed.amortization_schedule.periodic_payment.amount, :>,
      base.amortization_schedule.periodic_payment.amount
    # Every payment is sized at the changed rate, so nothing re-amortises
    # in-term and the card may call this figure THE monthly payment.
    assert_not changed.amortization_schedule.re_amortising?,
      "a change effective on the first payment resizes nothing in-term"
  end

  # CodeRabbit on we-promise/sure#3473: `re_amortising?` answered on event
  # presence, so a recorded change that never moves the repayment (the same
  # rate again, or one effective on the first payment) labelled a constant
  # payment "Opening Payment".
  test "re_amortising? is true only when the repayment actually moves in-term" do
    start_date = Date.new(2026, 1, 1)
    same_rate = build_loan(rate_type: "variable", term_months: 24, start_date: start_date,
                           variable_rate_schedule: { "2026-07-01" => "6.0" })
    moved = build_loan(rate_type: "variable", term_months: 24, start_date: start_date,
                       variable_rate_schedule: { "2026-07-01" => "7.0" })

    assert_not same_rate.amortization_schedule.re_amortising?, "the same rate again is not a resize"
    assert moved.amortization_schedule.re_amortising?
  end


  # `first_valuation_amount` is decimal(19,4) against two-decimal USD, so an
  # opening balance can carry sub-unit precision the schedule cannot represent.
  # Left unrounded it vanished in the first period and the principal portions
  # summed to less than the loan.
  test "an opening balance with sub-unit precision is still repaid exactly" do
    schedule = Loan::AmortizationSchedule.new(
      principal: BigDecimal("1000.1234"), annual_rate: 0, term_months: 4,
      start_date: Date.new(2026, 1, 1), currency: "USD"
    )
    repaid = schedule.payments.sum(BigDecimal("0")) { |p| p.principal.amount }

    assert_equal schedule.principal, repaid
    assert_equal BigDecimal("1000.12"), schedule.principal, "rounded to the currency at the door"
  end

  # A term the simulator refuses to walk must not reach it. `Simulator` raises
  # rather than truncating -- correct for the simulator -- but `amortizable?`
  # let such a loan through, so building the schedule for one raised
  # ArgumentError straight out of an account page render.
  #
  # Treated exactly as an unrecognised rate_type is: no schedule, no tab. The
  # tolerant answer matters because term_months is also written by
  # PlaidAccount::Liabilities::StudentLoanProcessor, from provider dates this
  # app does not control.
  test "a term longer than the simulator will walk is not amortizable, rather than raising" do
    loan = build_loan(rate_type: "fixed", term_months: Loan::Simulator::MAX_PERIODS + 1)

    assert_not loan.amortizable?
    assert_nil loan.amortization_schedule

    at_limit = build_loan(rate_type: "fixed", term_months: Loan::Simulator::MAX_PERIODS)
    assert at_limit.amortizable?, "the limit itself is still a schedulable loan"
    assert at_limit.amortization_schedule.payments.any?
  end

  # The rate input declares min="0" max="100"; a crafted PATCH does not have to
  # honour it. A rate outside that range parses fine and then silently drives
  # the projection.
  test "a rate outside the range the form declares is rejected, not persisted" do
    loan = build_loan(rate_type: "variable")

    [ "-1", "101", "1e1000" ].each do |bad|
      loan.rate_changes = [ { effective_date: "2027-01-01", rate: bad } ]

      assert_empty loan.variable_rate_schedule, "#{bad.inspect} should not have been stored"
      assert_equal [ { effective_date: "2027-01-01", rate: bad } ], loan.invalid_rate_changes
      assert_not loan.valid?, "#{bad.inspect} should fail validation so the form can redisplay it"
    end
  end

  test "the bounds themselves are accepted" do
    loan = build_loan(rate_type: "variable")
    loan.rate_changes = [ { effective_date: "2027-01-01", rate: "0" },
                          { effective_date: "2028-01-01", rate: "100" } ]

    assert_empty loan.invalid_rate_changes
    assert_equal({ "2027-01-01" => "0.0", "2028-01-01" => "100.0" }, loan.variable_rate_schedule)
  end

  # CodeRabbit on we-promise/sure#3474: the schedule is memoised on the loan.
  # Assigning any input it is built from must drop it, or a later read on the
  # same instance answers with the old terms.
  test "changing an input the schedule is built from rebuilds the schedule" do
    loan = build_loan(rate_type: "variable", term_months: 24, start_date: Date.new(2026, 1, 1))
    assert_not loan.amortization_schedule.re_amortising?

    loan.rate_changes = [ { effective_date: "2026-07-01", rate: "18" } ]
    assert loan.amortization_schedule.re_amortising?, "rate_changes= must drop the memoised schedule"

    opening_payment = loan.amortization_schedule.periodic_payment.amount
    loan.interest_rate = 9
    assert_operator loan.amortization_schedule.periodic_payment.amount, :>, opening_payment,
      "interest_rate= must drop the memoised schedule"

    loan.term_months = 12
    assert_equal 12, loan.amortization_schedule.payments.count, "term_months= must drop the memoised schedule"

    loan.reload
    assert_equal 24, loan.amortization_schedule.payments.count, "reload must drop the memoised schedule"
  end

  private
    def build_loan(rate_type:, interest_rate: 6, term_months: 360, start_date: nil,
                   variable_rate_schedule: {})
      Account.create!(
        family: @family,
        name: "Loan #{SecureRandom.hex(4)}",
        balance: 500_000,
        currency: "USD",
        accountable: Loan.new(
          subtype: "mortgage",
          interest_rate: interest_rate,
          term_months: term_months,
          rate_type: rate_type,
          start_date: start_date,
          variable_rate_schedule: variable_rate_schedule
        )
      ).loan
    end
end
