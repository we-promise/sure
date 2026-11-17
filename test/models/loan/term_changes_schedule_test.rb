require "test_helper"

# The schedule follows the recorded term changes. Every loan here is 12,000 at
# 12% over twelve months from 1 January 2026: a flat 1% a month, due on the
# first, at 1,066.19 a month. Unchanged it reads:
#
#   1  1 Feb  1,066.19  interest 120.00  balance 11,053.81
#   2  1 Mar  1,066.19  interest 110.54  balance 10,098.16
#   3  1 Apr  1,066.19  interest 100.98  balance  9,132.95
class Loan::TermChangesScheduleTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  MARCH = Date.new(2026, 3, 1)
  APRIL = Date.new(2026, 4, 1)
  MATURITY = Date.new(2027, 1, 1)

  setup do
    # Term changes cannot be dated in the future.
    travel_to Date.new(2027, 6, 1)
  end

  test "a loan without term changes keeps its schedule" do
    schedule = loan_with([]).amortization_schedule

    assert_equal 12, schedule.payments.size
    assert_equal BigDecimal("1066.19"), schedule.periodic_payment.amount
    assert_equal BigDecimal("12794.23"), schedule.total_paid.amount
    assert schedule.payments.none? { |payment| schedule.balance_adjustment_for(payment) }
    assert_not schedule.re_amortising?
  end

  test "an extra repayment lowers the balance on the next payment date and the payment after it" do
    schedule = loan_with([ { effective_date: "2026-03-15", extra_repayment: "2000" } ]).amortization_schedule
    april = schedule.payment_for(APRIL)

    assert_equal BigDecimal("100.98"), april.interest.amount, "the running period still charges the balance it opened with"
    assert_equal BigDecimal("-2000"), schedule.balance_adjustment_for(april).amount
    assert_equal BigDecimal("857.11"), april.payment.amount
    assert_equal BigDecimal("7342.03"), april.ending_balance.amount
    assert_equal BigDecimal("10098.16") - 2_000 - april.principal.amount, april.ending_balance.amount

    assert_equal MATURITY, schedule.payoff_date, "a lower payment keeps the end date"
    assert_equal 12, schedule.payments.size
    assert schedule.payments[2...-1].all? { |payment| payment.payment.amount == BigDecimal("857.11") }
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
    assert schedule.re_amortising?
  end

  test "an extra repayment with the old payment shortens the loan" do
    schedule = loan_with([
      { effective_date: "2026-03-15", extra_repayment: "2000", payment: "1066.19" }
    ]).amortization_schedule

    assert_equal BigDecimal("7132.95"), schedule.payment_for(APRIL).ending_balance.amount
    assert_equal Date.new(2026, 11, 1), schedule.payoff_date
    assert_equal 10, schedule.payments.size
    assert schedule.payments[0...-1].all? { |payment| payment.payment.amount == BigDecimal("1066.19") }
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
    assert_not schedule.re_amortising?, "the payment never moved"
  end

  test "an extra repayment a few days after a payment date lowers the balance that period charges" do
    schedule = loan_with([ { effective_date: "2026-03-03", extra_repayment: "2000" } ]).amortization_schedule
    april = schedule.payment_for(APRIL)

    assert_equal BigDecimal("80.98"), april.interest.amount
    assert_equal BigDecimal("855.02"), april.payment.amount
    assert_equal BigDecimal("-2000"), schedule.balance_adjustment_for(april).amount
    assert_equal BigDecimal("7324.12"), april.ending_balance.amount
  end

  test "an extra repayment after the grace days waits for the payment date" do
    grace = Loan::PrincipalPayments::PAYMENT_GRACE_DAYS
    inside = loan_with([ { effective_date: (MARCH + grace).iso8601, extra_repayment: "2000" } ]).amortization_schedule
    outside = loan_with([ { effective_date: (MARCH + grace + 1).iso8601, extra_repayment: "2000" } ]).amortization_schedule

    assert_equal BigDecimal("80.98"), inside.payment_for(APRIL).interest.amount
    assert_equal BigDecimal("100.98"), outside.payment_for(APRIL).interest.amount
  end

  # The lender collected that day's instalment before the repayment, so the
  # repayment comes off after it and the instalment changes from the next one,
  # as with a balance confirmed for a payment date.
  test "an extra repayment on a payment date comes off after that day's payment" do
    schedule = loan_with([ { effective_date: "2026-04-01", extra_repayment: "2000" } ]).amortization_schedule
    april = schedule.payment_for(APRIL)
    may = schedule.payments[3]

    assert_equal BigDecimal("100.98"), april.interest.amount
    assert_equal BigDecimal("1066.19"), april.payment.amount, "that day's payment is behind the repayment"
    assert_equal BigDecimal("-2000"), schedule.balance_adjustment_for(april).amount
    assert_equal BigDecimal("7132.95"), april.ending_balance.amount
    assert_equal BigDecimal("71.33"), may.interest.amount
    assert_equal BigDecimal("832.70"), may.payment.amount, "re-amortised from the next payment"
    assert_equal MATURITY, schedule.payoff_date
  end

  test "an extra repayment with a new payment on a payment date sets the payment from the next one" do
    schedule = loan_with([
      { effective_date: "2026-04-01", extra_repayment: "2000", payment: "1200" }
    ]).amortization_schedule

    assert_equal BigDecimal("1066.19"), schedule.payment_for(APRIL).payment.amount, "that day's payment is behind the repayment"
    assert_equal BigDecimal("7132.95"), schedule.payment_for(APRIL).ending_balance.amount
    assert_equal BigDecimal("1200"), schedule.payment_for(APRIL >> 1).payment.amount
    assert_equal BigDecimal("1200"), schedule.payment_in_force(APRIL + 1).amount
    assert_operator schedule.payoff_date, :<, MATURITY, "the higher payment shortens the loan"
  end

  test "a confirmed balance part-way through a period charges the rest of it on that balance" do
    schedule = loan_with([ { effective_date: "2026-03-16", balance: "9000" } ]).amortization_schedule
    april = schedule.payment_for(APRIL)

    # 15 days of a 30/360 year at 12% on 9,000.
    assert_equal BigDecimal("45"), april.interest.amount
    assert_equal BigDecimal("-1098.16"), schedule.balance_adjustment_for(april).amount
    assert_equal BigDecimal("945.53"), april.payment.amount
    assert_equal BigDecimal("9000") - april.principal.amount, april.ending_balance.amount
    assert_equal MATURITY, schedule.payoff_date
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
  end

  test "a confirmed balance on a payment date is the balance after that payment" do
    schedule = loan_with([ { effective_date: "2026-03-01", balance: "10000" } ]).amortization_schedule
    march = schedule.payment_for(MARCH)
    april = schedule.payment_for(APRIL)

    assert_equal BigDecimal("1066.19"), march.payment.amount, "that day's payment is behind the confirmed balance"
    assert_equal BigDecimal("10000"), march.ending_balance.amount
    assert_equal BigDecimal("-98.16"), schedule.balance_adjustment_for(march).amount
    assert_equal BigDecimal("100"), april.interest.amount
    assert_equal BigDecimal("1055.82"), april.payment.amount, "re-amortised from the next payment"
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
  end

  test "a confirmed balance with a new payment on a payment date sets the payment from the next one" do
    schedule = loan_with([ { effective_date: "2026-03-01", balance: "10000", payment: "1200" } ]).amortization_schedule
    march = schedule.payment_for(MARCH)

    assert_equal BigDecimal("1066.19"), march.payment.amount, "that day's payment is behind the confirmed balance"
    assert_equal BigDecimal("955.65"), march.principal.amount
    assert_equal BigDecimal("-98.16"), schedule.balance_adjustment_for(march).amount
    assert_equal BigDecimal("1200"), schedule.payment_for(APRIL).payment.amount
    assert_equal BigDecimal("1066.19"), schedule.payment_in_force(MARCH).amount
    assert_equal BigDecimal("1200"), schedule.payment_in_force(MARCH + 1).amount
  end

  test "a change in the next period overrides the payment a confirmed balance left for it" do
    resized = loan_with([
      { effective_date: "2026-03-01", balance: "10000", payment: "1200" },
      { effective_date: "2026-03-15", extra_repayment: "2000" }
    ]).amortization_schedule
    held = loan_with([
      { effective_date: "2026-03-01", balance: "10000" },
      { effective_date: "2026-03-15", payment: "1300" }
    ]).amortization_schedule

    assert_operator resized.payment_for(APRIL).payment.amount, :<, BigDecimal("1066.19"),
                    "the later change re-amortises instead of keeping 1,200"
    assert_equal BigDecimal("1300"), held.payment_for(APRIL).payment.amount
  end

  test "a confirmed balance above the schedule raises the payment" do
    schedule = loan_with([ { effective_date: "2026-03-01", balance: "10500" } ]).amortization_schedule

    assert_equal BigDecimal("401.84"), schedule.balance_adjustment_for(schedule.payment_for(MARCH)).amount
    assert_operator schedule.payment_for(APRIL).payment.amount, :>, BigDecimal("1066.19")
    assert_equal BigDecimal("12000") + BigDecimal("401.84") + schedule.total_interest.amount, schedule.total_paid.amount,
                 "a balance that went up is repaid through the payments, not counted as a payment itself"
  end

  test "a payment on its own holds from the first payment on or after its date" do
    schedule = loan_with([ { effective_date: "2026-03-20", payment: "1200" } ]).amortization_schedule

    assert_equal BigDecimal("1066.19"), schedule.payment_for(MARCH).payment.amount
    assert_equal BigDecimal("1200"), schedule.payment_for(APRIL).payment.amount
    assert schedule.payments.none? { |payment| schedule.balance_adjustment_for(payment) }
    assert_equal Date.new(2026, 12, 1), schedule.payoff_date
    assert schedule.re_amortising?
  end

  # The April period charges 100.98. A payment below that would let the
  # balance grow, which the schedule and the ledger replay treat differently.
  test "a payment that does not cover its period's interest is refused" do
    loan = loan_with([])

    [ "0", "50", "100.97" ].each do |payment|
      loan.term_change_rows = [ { effective_date: "2026-04-01", payment: payment } ]

      assert_not loan.valid?, payment
      assert_includes loan.errors.full_messages, I18n.t("activerecord.errors.models.loan.term_change_payment_below_interest")
    end

    loan.term_change_rows = [ { effective_date: "2026-04-01", payment: "100.98" } ]
    assert loan.valid?, "a payment equal to the interest keeps the balance level"
    assert_equal BigDecimal("10098.16"), loan.amortization_schedule.payment_for(APRIL).ending_balance.amount
  end

  # 100,000 at 15% over 30 years on actual/365: the level payment is 1,264.44
  # and a 31-day period charges 1,273.97, with no term change at all. Only
  # the lender's own payment is judged.
  test "a lender's payment is not refused for interest the level payment already falls short of" do
    account = create_loan_account(
      term_months: 360, initial_balance: 100_000, interest_rate: 15, day_count_convention: "actual_365",
      entries: [ { type: "opening_anchor", date: Date.new(2026, 1, 1), balance: 100_000 } ]
    )
    loan = account.loan
    assert loan.amortization_schedule.payments.first.principal.amount.negative?, "premise: the level payment falls short"

    loan.term_change_rows = [ { effective_date: "2026-02-10", payment: "1300" } ]
    assert loan.valid?, loan.errors.full_messages.to_sentence

    loan.term_change_rows = [ { effective_date: "2026-02-10", payment: "1100" } ]
    assert_not loan.valid?
    assert_includes loan.errors.full_messages, I18n.t("activerecord.errors.models.loan.term_change_payment_below_interest")
  end

  test "a payment that falls below the interest after a higher confirmed balance is refused" do
    loan = loan_with([])
    loan.term_change_rows = [ { effective_date: "2026-03-16", balance: "500000", payment: "1066.19" } ]

    assert_not loan.valid?
    assert_includes loan.errors.full_messages, I18n.t("activerecord.errors.models.loan.term_change_payment_below_interest")
  end

  # The final row settles whatever is owed, so its principal never goes
  # negative. The last period charges 10.56.
  test "a payment below the interest is refused on the final payment date too" do
    loan = loan_with([])

    loan.term_change_rows = [ { effective_date: "2026-12-15", payment: "10" } ]
    assert_not loan.valid?
    assert_includes loan.errors.full_messages, I18n.t("activerecord.errors.models.loan.term_change_payment_below_interest")

    loan.term_change_rows = [ { effective_date: "2026-12-15", payment: "10.56" } ]
    assert loan.valid?, loan.errors.full_messages.to_sentence
    assert_equal MATURITY, loan.amortization_schedule.payoff_date
  end

  # The row settles the period's 100.98 of interest and nothing is left to
  # grow, so the payment of zero that follows a payoff is not a short one.
  test "a payoff recorded with a payment of zero is accepted" do
    [ "2026-03-20", "2026-04-01" ].each do |date|
      loan = loan_with([])
      loan.term_change_rows = [ { effective_date: date, extra_repayment: "10098.16", payment: "0" } ]

      assert loan.valid?, loan.errors.full_messages.to_sentence
      assert_equal APRIL, loan.amortization_schedule.payoff_date, date
    end
  end

  # March closes on 10,098.16. The lender confirms 1,000 more, and 2,000 is
  # repaid later in the same period: the row's balance moves by -1,000, and
  # 2,000 was repaid outside the instalments.
  test "a higher confirmed balance does not offset a repayment in the same period" do
    schedule = loan_with([
      { effective_date: "2026-03-10", balance: "11098.16" },
      { effective_date: "2026-03-20", extra_repayment: "2000" }
    ]).amortization_schedule

    assert_equal BigDecimal("-1000"), schedule.balance_adjustment_for(schedule.payment_for(APRIL)).amount
    assert_equal BigDecimal("12000") + BigDecimal("1000") + schedule.total_interest.amount, schedule.total_paid.amount
    assert_equal schedule.total_paid.amount,
                 schedule.payments.sum { |payment| payment.payment.amount } + BigDecimal("2000")
  end

  # The same 2,000, whichever side of the grace days or of the confirmed
  # balance it is dated on, and whether that balance is above or below the
  # one before it.
  test "a repayment counts in full whatever order it and a confirmed balance come in" do
    [ "11098.16", "9098.16" ].each do |confirmed|
      [ "2026-03-03", "2026-03-10" ].each do |repaid_on|
        schedule = loan_with([
          { effective_date: repaid_on, extra_repayment: "2000" },
          { effective_date: "2026-03-20", balance: confirmed }
        ]).amortization_schedule

        assert_equal schedule.payments.sum { |payment| payment.payment.amount } + BigDecimal("2000"),
                     schedule.total_paid.amount, "#{repaid_on}, #{confirmed}"
      end
    end
  end

  test "a later change overrides an earlier one from its own date" do
    schedule = loan_with([
      { effective_date: "2026-03-15", extra_repayment: "2000" },
      { effective_date: "2026-06-10", extra_repayment: "1000", payment: "857.11" }
    ]).amortization_schedule
    july = schedule.payment_for(Date.new(2026, 7, 1))

    assert_equal BigDecimal("-1000"), schedule.balance_adjustment_for(july).amount
    assert_equal BigDecimal("857.11"), july.payment.amount
    assert_operator schedule.payoff_date, :<, MATURITY
    assert_equal BigDecimal("12000"), principal_and_adjustments(schedule)
  end

  test "two extra repayments in one period add up" do
    schedule = loan_with([
      { effective_date: "2026-03-10", extra_repayment: "500" },
      { effective_date: "2026-03-20", extra_repayment: "1500" }
    ]).amortization_schedule
    single = loan_with([ { effective_date: "2026-03-15", extra_repayment: "2000" } ]).amortization_schedule

    assert_equal single.payments.map(&:ending_balance), schedule.payments.map(&:ending_balance)
  end

  test "a confirmed balance puts an earlier extra repayment in the same period behind it" do
    schedule = loan_with([
      { effective_date: "2026-03-10", extra_repayment: "500" },
      { effective_date: "2026-03-16", balance: "9000" }
    ]).amortization_schedule
    alone = loan_with([ { effective_date: "2026-03-16", balance: "9000" } ]).amortization_schedule

    assert_equal alone.payments.map(&:ending_balance), schedule.payments.map(&:ending_balance)
  end

  test "an extra repayment after a confirmed balance in the same period comes off on the payment date" do
    schedule = loan_with([
      { effective_date: "2026-03-03", balance: "10000" },
      { effective_date: "2026-03-05", extra_repayment: "1000" }
    ]).amortization_schedule
    april = schedule.payment_for(APRIL)

    # 28 days of a 30/360 year at 12% on the confirmed 10,000: the grace days
    # count from a payment date, not from a balance confirmed after it.
    assert_equal BigDecimal("93.33"), april.interest.amount
    assert_equal BigDecimal("-1098.16"), schedule.balance_adjustment_for(april).amount
    assert_equal BigDecimal("9000") - april.principal.amount, april.ending_balance.amount
  end

  test "an extra repayment larger than the balance ends the loan with that period's interest" do
    schedule = loan_with([ { effective_date: "2026-03-15", extra_repayment: "20000" } ]).amortization_schedule
    april = schedule.payments.last

    assert_equal APRIL, schedule.payoff_date
    assert_equal BigDecimal("100.98"), april.payment.amount
    assert_equal BigDecimal("100.98"), april.interest.amount
    assert_equal BigDecimal("0"), april.principal.amount
    assert_equal BigDecimal("-10098.16"), schedule.balance_adjustment_for(april).amount, "only what was owed is repaid"
    assert_equal BigDecimal("0"), april.ending_balance.amount
  end

  test "an extra repayment larger than the balance inside the grace days leaves nothing to charge" do
    schedule = loan_with([ { effective_date: "2026-03-03", extra_repayment: "20000" } ]).amortization_schedule
    april = schedule.payments.last

    assert_equal APRIL, april.date
    assert_equal BigDecimal("0"), april.payment.amount
    assert_equal BigDecimal("0"), april.interest.amount
    assert_equal BigDecimal("-10098.16"), schedule.balance_adjustment_for(april).amount
    assert_equal BigDecimal("0"), april.ending_balance.amount
  end

  # The form refuses such a row; one stored before the term was shortened is
  # still read.
  test "a balance confirmed on the last payment date leaves the loan without a payoff date" do
    loan = loan_with([])
    loan.term_changes.create!(effective_date: MATURITY, balance: 500)
    schedule = loan.reload.amortization_schedule

    assert_equal BigDecimal("500"), schedule.payments.last.ending_balance.amount
    assert_nil schedule.payoff_date
    assert_nil schedule.payment_in_force(MATURITY + 1)
    assert_nil schedule.total_paid, "a total without the balance owed would understate the cost"
    assert_nil loan.total_cost
  end

  # The factor is the period's own, not one read back from rounded interest:
  # half a month at 12% on a small confirmed balance rounds to 0.50.
  test "the projection charges a part period at its exact factor" do
    account = loan_account_with([ { effective_date: "2026-03-16", balance: "100.99" } ])
    account.update!(balance: 10_000)

    projection = account.reload.loan.payoff_projection(as_of: AS_OF)

    assert_equal BigDecimal("50"), projection.payments.first[:interest_payment]
  end

  test "a confirmed balance of zero ends the loan" do
    schedule = loan_with([ { effective_date: "2026-03-01", balance: "0" } ]).amortization_schedule

    assert_equal MARCH, schedule.payoff_date
    assert_equal BigDecimal("0"), schedule.payments.last.ending_balance.amount
  end

  test "principal and extra repayments add up to the amount borrowed" do
    schedule = loan_with([
      { effective_date: "2026-03-15", extra_repayment: "2000" },
      { effective_date: "2026-08-01", extra_repayment: "750.50" }
    ]).amortization_schedule

    assert_equal BigDecimal("12000"), principal_and_adjustments(schedule)
    assert_equal BigDecimal("12000") + schedule.total_interest.amount, schedule.total_paid.amount
  end

  # Both changes fall in the period that closes on 1 April. The one dated
  # later decides that payment.
  test "a rate change after a lender's payment in the same period re-amortises" do
    schedule = loan_with(
      [ { effective_date: "2026-03-10", payment: "1200" } ],
      rate_type: "variable", variable_rate_schedule: { "2026-03-20" => "6" }
    ).amortization_schedule
    april = schedule.payment_for(APRIL)

    assert_operator april.payment.amount, :<, BigDecimal("1066.19"), "re-amortised at 6%, not held at 1,200"
    assert_equal april.payment, schedule.payment_for(Date.new(2026, 5, 1)).payment
    assert_equal MATURITY, schedule.payoff_date
  end

  test "a lender's payment after a rate change in the same period holds" do
    schedule = loan_with(
      [ { effective_date: "2026-03-20", payment: "1200" } ],
      rate_type: "variable", variable_rate_schedule: { "2026-03-10" => "6" }
    ).amortization_schedule

    assert_equal BigDecimal("1200"), schedule.payment_for(APRIL).payment.amount
    assert_equal BigDecimal("1200"), schedule.payment_for(Date.new(2026, 5, 1)).payment.amount
  end

  test "a lender's payment on the day the rate changes holds" do
    schedule = loan_with(
      [ { effective_date: "2026-03-20", payment: "1200" } ],
      rate_type: "variable", variable_rate_schedule: { "2026-03-20" => "6" }
    ).amortization_schedule

    assert_equal BigDecimal("1200"), schedule.payment_for(APRIL).payment.amount
  end

  # The first period has no payment before it to compare rates with.
  test "a rate change after a lender's payment re-amortises in the first period too" do
    schedule = loan_with(
      [ { effective_date: "2026-01-10", payment: "1200" } ],
      rate_type: "variable", variable_rate_schedule: { "2026-01-20" => "6" }
    ).amortization_schedule
    first = schedule.payments.first

    assert_operator first.payment.amount, :<, BigDecimal("1066.19"), "re-amortised at 6%, not held at 1,200"
    assert_equal first.payment, schedule.payments[1].payment
    assert_equal MATURITY, schedule.payoff_date
  end

  test "a lender's payment after a rate change holds in the first period" do
    schedule = loan_with(
      [ { effective_date: "2026-01-20", payment: "1200" } ],
      rate_type: "variable", variable_rate_schedule: { "2026-01-10" => "6" }
    ).amortization_schedule

    assert_equal BigDecimal("1200"), schedule.payments.first.payment.amount
    assert_equal BigDecimal("1200"), schedule.payments[1].payment.amount
  end

  test "a lender's payment holds until the rate moves" do
    loan = loan_with(
      [ { effective_date: "2026-03-15", extra_repayment: "2000", payment: "1066.19" } ],
      rate_type: "variable", variable_rate_schedule: { "2026-07-01" => "6" }
    )
    schedule = loan.amortization_schedule

    assert_equal BigDecimal("1066.19"), schedule.payment_for(Date.new(2026, 6, 1)).payment.amount
    assert_equal BigDecimal("751.79"), schedule.payment_for(Date.new(2026, 7, 1)).payment.amount
    assert_equal MATURITY, schedule.payoff_date, "a rate change re-amortises over the contract's own term"
  end

  # The balance on the day the loan began is its opening balance. The ledger
  # replay resets to it that day, so a change dated then could not match.
  test "a change on the origination date is refused" do
    loan = loan_with([])

    [ { effective_date: "2026-01-01", balance: "10000" }, { effective_date: "2026-01-01", extra_repayment: "500" } ].each do |row|
      loan.term_change_rows = [ row ]

      assert_not loan.valid?, row.inspect
      assert_includes loan.errors.full_messages, I18n.t("activerecord.errors.models.loan.term_change_not_after_origination")
    end
  end

  test "an extra repayment in the grace days of the first period lowers what it charges" do
    schedule = loan_with([ { effective_date: "2026-01-04", extra_repayment: "2000" } ]).amortization_schedule

    assert_equal BigDecimal("100"), schedule.payments.first.interest.amount
  end

  # The schedule ends on its last payment and does not read a row dated after
  # it, so the form refuses the row instead of storing it without effect.
  test "a change dated after the loan was cleared is refused" do
    loan = loan_with([ { effective_date: "2026-03-01", balance: "0" } ])
    cleared = loan.amortization_schedule.payments

    loan.term_change_rows = [
      { effective_date: "2026-03-01", balance: "0" },
      { effective_date: "2026-06-10", balance: "500" }
    ]

    assert_not loan.valid?
    assert_includes loan.errors.full_messages, I18n.t("activerecord.errors.models.loan.term_change_after_last_payment")
    assert_equal cleared, loan.amortization_schedule.payments, "the schedule itself leaves such a row unread"
  end

  # A payment of 1,300 from April repays the loan on 1 November. A balance
  # the lender confirms for that day is read, and the schedule runs on from
  # it to the end of the term.
  test "a balance confirmed on the last payment of a schedule that ended early runs it on" do
    held = [ { effective_date: "2026-03-20", payment: "1300" } ]
    ended = loan_with(held).amortization_schedule.payoff_date
    assert_operator ended, :<, MATURITY, "premise: the held payment ends the schedule early"

    loan = loan_with(held)
    loan.term_change_rows = held + [ { effective_date: ended.iso8601, balance: "500" } ]

    assert loan.valid?, loan.errors.full_messages.to_sentence
    schedule = loan.amortization_schedule
    assert_equal BigDecimal("500"), schedule.payment_for(ended).ending_balance.amount
    assert_equal MATURITY, schedule.payoff_date
  end

  test "a change dated after the last payment of the term is refused" do
    loan = loan_with([])

    loan.term_change_rows = [ { effective_date: "2027-02-01", extra_repayment: "500" } ]
    assert_not loan.valid?
    assert_includes loan.errors.full_messages, I18n.t("activerecord.errors.models.loan.term_change_after_last_payment")

    loan.term_change_rows = [ { effective_date: MATURITY.iso8601, payment: "1100" } ]
    assert loan.valid?, "a change on the last payment date is accepted"
  end

  # That day's payment comes first and repays the loan, so the repayment has
  # nothing left to repay.
  test "an extra repayment on the last payment date is refused" do
    loan = loan_with([])

    loan.term_change_rows = [ { effective_date: MATURITY.iso8601, extra_repayment: "500" } ]
    assert_not loan.valid?
    assert_includes loan.errors.full_messages, I18n.t("activerecord.errors.models.loan.term_change_repayment_after_payoff")

    loan.term_change_rows = [ { effective_date: (MATURITY << 1).iso8601, extra_repayment: "500" } ]
    assert loan.valid?, loan.errors.full_messages.to_sentence

    loan.term_change_rows = [ { effective_date: APRIL.iso8601, extra_repayment: "20000" } ]
    assert loan.valid?, "a repayment that ends the loan on its date is read"
    assert_equal APRIL, loan.amortization_schedule.payoff_date
  end

  # No payment is left to repay what the lender confirmed, so the schedule
  # would end with the loan still owing.
  test "a balance left owing after the last payment of the term is refused" do
    loan = loan_with([])

    loan.term_change_rows = [ { effective_date: MATURITY.iso8601, balance: "500" } ]
    assert_not loan.valid?
    assert_includes loan.errors.full_messages, I18n.t("activerecord.errors.models.loan.term_change_balance_after_last_payment")

    loan.term_change_rows = [ { effective_date: MATURITY.iso8601, balance: "0" } ]
    assert loan.valid?, loan.errors.full_messages.to_sentence
  end

  test "the day count convention sizes the part period of a confirmed balance" do
    schedule = loan_with(
      [ { effective_date: "2026-03-16", balance: "9000" } ], day_count_convention: "actual_365"
    ).amortization_schedule

    # 16 actual days at 12% on 9,000.
    assert_equal BigDecimal("47.34"), schedule.payment_for(APRIL).interest.amount
  end

  test "a loan with a term change has no single monthly payment" do
    loan = loan_with([ { effective_date: "2026-03-15", extra_repayment: "2000" } ])

    assert loan.repayment_varies?
    assert_nil loan.monthly_payment
    assert_equal BigDecimal("1066.19"), loan.amortization_schedule.payment_in_force(MARCH).amount
    assert_equal BigDecimal("857.11"), loan.amortization_schedule.payment_in_force(MARCH + 1).amount
  end

  test "a fixed loan without term changes still has its monthly payment" do
    loan = loan_with([])

    assert_not loan.repayment_varies?
    assert_equal BigDecimal("1066.19"), loan.monthly_payment.amount
  end

  test "insurance on the declining balance follows the term changes" do
    plain = loan_with([], insurance_rate: 1.2, insurance_rate_type: "decreasing_life")
    changed = loan_with(
      [ { effective_date: "2026-03-15", extra_repayment: "2000" } ],
      insurance_rate: 1.2, insurance_rate_type: "decreasing_life"
    )

    # 0.1% a month on the balance each period opened with.
    assert_equal BigDecimal("9.13"), plain.insurance.premium_for(4).amount.amount
    assert_equal BigDecimal("7.34"), changed.insurance.premium_for(4).amount.amount
  end

  # Inside the period a balance-moving change is dated in, the projection
  # charges today's balance the way the schedule's row charged its own. A
  # full period on today's balance is a different amount, and against a
  # payment sized to the cent it reads as a balloon. The balances below come
  # from the ledger, as the account page's do.
  AS_OF = Date.new(2026, 3, 20)

  test "the projection stays on contract in the period of a confirmed balance" do
    [ false, true ].each do |preview|
      account = loan_account_with([ { effective_date: "2026-03-16", balance: "9000" } ])
      enable_preview_features_for_family!(account.family) if preview
      assert_equal preview, account.loan.principal_replay_active?
      pay_instalments(account, through: AS_OF)
      account.entries.create!(name: "Balance update", date: Date.new(2026, 3, 16), amount: 9_000,
                              currency: account.currency, entryable: Valuation.new(kind: "reconciliation"))

      projection = project_from_ledger(account)

      assert_equal BigDecimal("9000"), projection.current_balance.amount
      assert_equal BigDecimal("45"), projection.payments.first[:interest_payment], "preview #{preview}"
      assert projection.converged?
      assert_equal MATURITY, projection.payoff_date
      assert_equal BigDecimal("0"), projection.interest_saved.amount
    end
  end

  # With the replay on, the linked transfer paid the period's 100.98 interest
  # first, so the balance is 10,098.16 - 2,000 + 100.98.
  test "the projection stays on contract after an extra repayment that paid the period's interest" do
    account = loan_account_with([ { effective_date: "2026-03-15", extra_repayment: "2000" } ])
    enable_preview_features_for_family!(account.family)
    pay_instalments(account, through: AS_OF)
    create_linked_loan_payment(account, 2_000, Date.new(2026, 3, 15))

    projection = project_from_ledger(account)

    assert_equal BigDecimal("8199.14"), projection.current_balance.amount
    assert_equal BigDecimal("0"), projection.payments.first[:interest_payment]
    assert_equal BigDecimal("7342.03"), projection.payments.first[:ending_balance]
    assert projection.converged?
    assert_equal MATURITY, projection.payoff_date
    assert_equal BigDecimal("0"), projection.interest_saved.amount
  end

  test "the projection stays on contract after an extra repayment smaller than the period's interest" do
    account = loan_account_with([ { effective_date: "2026-03-15", extra_repayment: "40" } ])
    enable_preview_features_for_family!(account.family)
    pay_instalments(account, through: AS_OF)
    create_linked_loan_payment(account, 40, Date.new(2026, 3, 15))

    projection = project_from_ledger(account)

    assert_equal BigDecimal("10098.16"), projection.current_balance.amount, "the transfer paid interest only"
    assert_equal BigDecimal("60.98"), projection.payments.first[:interest_payment]
    assert projection.converged?
    assert_equal BigDecimal("0"), projection.interest_saved.amount
  end

  # With principal-only transfers the borrower pays the interest separately,
  # so the balance is 10,098.16 - 2,000 and the interest is still to pay.
  test "the projection stays on contract after a principal-only extra repayment" do
    [ false, true ].each do |preview|
      account = loan_account_with(
        [ { effective_date: "2026-03-15", extra_repayment: "2000" } ], principal_only_transfers: true
      )
      enable_preview_features_for_family!(account.family) if preview
      assert_equal preview, account.loan.principal_replay_active?
      account.loan.amortization_schedule.payments.select { |payment| payment.date <= AS_OF }.each do |instalment|
        create_linked_loan_payment(account, instalment.principal.amount, instalment.date)
      end
      create_linked_loan_payment(account, 2_000, Date.new(2026, 3, 15))

      projection = project_from_ledger(account)

      assert_equal BigDecimal("8098.16"), projection.current_balance.amount
      assert_equal BigDecimal("100.98"), projection.payments.first[:interest_payment], "preview #{preview}"
      assert_equal BigDecimal("7342.03"), projection.payments.first[:ending_balance]
      assert projection.converged?
      assert_equal BigDecimal("0"), projection.interest_saved.amount
    end
  end

  test "the projection stays on contract after an extra repayment in the grace days" do
    account = loan_account_with([ { effective_date: "2026-03-03", extra_repayment: "2000" } ])
    enable_preview_features_for_family!(account.family)
    pay_instalments(account, through: AS_OF)
    create_linked_loan_payment(account, 2_000, Date.new(2026, 3, 3))

    projection = project_from_ledger(account)

    assert_equal BigDecimal("8098.16"), projection.current_balance.amount
    assert_equal BigDecimal("80.98"), projection.payments.first[:interest_payment]
    assert projection.converged?
    assert_equal BigDecimal("0"), projection.interest_saved.amount
  end

  # Without the replay a payment comes off the balance whole, so the ledger
  # is already ahead of the contract and the period's interest is still to
  # pay: it is charged on the balance before the repayment.
  test "the projection charges the balance before the repayment when the replay is off" do
    account = loan_account_with([ { effective_date: "2026-03-15", extra_repayment: "2000" } ])
    assert_not account.loan.principal_replay_active?
    pay_instalments(account, through: AS_OF)
    create_linked_loan_payment(account, 2_000, Date.new(2026, 3, 15))

    projection = project_from_ledger(account)

    assert_equal BigDecimal("7867.62"), projection.current_balance.amount
    # 1% of 7,867.62 + 2,000.
    assert_equal BigDecimal("98.68"), projection.payments.first[:interest_payment]
    assert projection.converged?
  end

  # A change of the payment alone leaves the period's charge alone, so a
  # borrower who is ahead of the contract is charged on what they owe.
  test "a payment-only change in the current period charges today's balance" do
    account = loan_account_with([ { effective_date: "2026-03-15", payment: "1200" } ])
    account.update!(balance: 5_000)

    projection = account.reload.loan.payoff_projection(as_of: AS_OF)

    assert_equal BigDecimal("50"), projection.payments.first[:interest_payment]
    assert_equal BigDecimal("1200"), projection.payments.first[:payment_amount]
  end

  test "the projection charges today's balance when no change is dated in the current period" do
    account = loan_account_with([ { effective_date: "2026-02-10", extra_repayment: "2000" } ])
    account.update!(balance: 5_000)

    projection = account.reload.loan.payoff_projection(as_of: Date.new(2026, 3, 20))

    assert_equal BigDecimal("50"), projection.payments.first[:interest_payment]
  end

  test "the payoff projection pays the changed contract" do
    account = loan_account_with([ { effective_date: "2026-03-15", extra_repayment: "2000" } ])
    schedule = account.loan.amortization_schedule
    account.update!(balance: schedule.payment_for(APRIL).ending_balance.amount)

    projection = account.reload.loan.payoff_projection(as_of: APRIL)

    assert projection.converged?
    assert_equal MATURITY, projection.payoff_date
    assert_equal 0, projection.months_saved
  end

  # An interest-free loan of 12,000 repays 1,000 a month. The lender pauses
  # the April payment and asks 1,100 from May, which repays the loan by its
  # end. On 20 March the next payment is zero and a later one repays.
  test "a payment holiday on an interest-free loan still projects" do
    account = loan_account_with([
      { effective_date: "2026-03-15", payment: "0" },
      { effective_date: "2026-04-15", payment: "1100" }
    ], interest_rate: 0)
    pay_instalments(account, through: AS_OF)

    projection = project_from_ledger(account)

    assert_equal BigDecimal("10000"), projection.current_balance.amount
    assert projection.applicable?
    assert_equal BigDecimal("0"), projection.payments.first[:payment_amount]
    assert projection.converged?
    assert_equal BigDecimal("0"), projection.interest_saved.amount
  end

  private
    def loan_with(rows, **loan_attrs)
      loan_account_with(rows, **loan_attrs).loan
    end

    def loan_account_with(rows, **loan_attrs)
      account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
        { type: "opening_anchor", date: Date.new(2026, 1, 1), balance: 12_000 }
      ], **loan_attrs)
      account.loan.update!(term_change_rows: rows)
      account.reload
    end

    # One unlinked payment per instalment due on or before `through`.
    def pay_instalments(account, through:)
      account.loan.amortization_schedule.payments.select { |payment| payment.date <= through }.each do |instalment|
        account.entries.create!(name: "Payment", date: instalment.date, amount: -instalment.payment.amount,
                                currency: account.currency, entryable: Transaction.new)
      end
    end

    # The projection on AS_OF from the balance the ledger gives for that day.
    def project_from_ledger(account)
      travel_to AS_OF
      account.reload
      # The calculator stops at the last entry; the balance holds from there.
      balance = Balance::ForwardCalculator.new(account).calculate
        .select { |row| row.date <= AS_OF }.max_by(&:date).balance
      account.update!(balance: balance)

      account.reload.loan.payoff_projection(as_of: AS_OF)
    end

    # Everything that brought the balance down: the principal in the payments
    # and what the term changes took off.
    def principal_and_adjustments(schedule)
      schedule.payments.sum(BigDecimal("0")) do |payment|
        payment.principal.amount - (schedule.balance_adjustment_for(payment)&.amount || 0)
      end
    end
end
