require "test_helper"

# A lender states its rate with a compounding. Canadian fixed-rate mortgages
# state it compounded half-yearly (Interest Act, s. 6), so a month charges
# (1 + r/2)^(1/6) - 1 rather than r/12, and the payment is sized at that rate.
#
# The load-bearing test here is that the DEFAULT still charges exactly what it
# charged before, on every day count: the engine is the single accrual point
# for every loan figure, so a default that moved would restate every schedule.
#
# Every figure below is computed by hand from the formula, not read back out of
# the engine: CAD 100,000 at 4.40% over 20 years.
class Loan::InterestCompoundingTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  BALANCE = 100_000
  RATE = BigDecimal("4.4")
  MONTHS = 240

  test "the default compounding is the rate divided by the period, on every day count" do
    assert_equal Loan::AmortizationMath.monthly_rate(RATE), Loan::AmortizationMath.monthly_rate(RATE, compounding: :per_period)
    assert_equal RATE / 100 / 12, Loan::AmortizationMath.monthly_rate(RATE, compounding: nil)

    [
      [ :thirty_360, true ], [ :thirty_360, false ], [ :actual_365, true ], [ :actual_actual, true ]
    ].each do |convention, full_period|
      args = { annual_percentage: RATE, period_start: Date.new(2028, 1, 15), period_end: Date.new(2028, 2, 29),
               day_count_convention: convention, full_period: full_period }

      assert_equal Loan::AmortizationMath.accrual_factor(**args),
                   Loan::AmortizationMath.accrual_factor(**args, compounding: :per_period),
                   "#{convention} (full period: #{full_period}) moved under the default compounding"
    end
  end

  test "half-yearly compounding charges the rate's monthly equivalent" do
    assert_in_delta BigDecimal("0.003633500513137932632"),
                    Loan::AmortizationMath.monthly_rate(RATE, compounding: :semi_annual), BigDecimal("1e-18"),
                    "(1 + 0.044/2)^(1/6) - 1"
    assert_equal BigDecimal("363.35"), interest_for(Date.new(2026, 1, 1), Date.new(2026, 2, 1), :thirty_360, :semi_annual)
    assert_equal BigDecimal("366.67"), interest_for(Date.new(2026, 1, 1), Date.new(2026, 2, 1), :thirty_360, :per_period),
                 "the same month at 4.40% / 12, for comparison"
  end

  test "yearly compounding charges the rate's monthly equivalent" do
    assert_in_delta BigDecimal("0.003594736411045118032"),
                    Loan::AmortizationMath.monthly_rate(RATE, compounding: :annual), BigDecimal("1e-18"),
                    "(1 + 0.044)^(1/12) - 1"
    assert_equal BigDecimal("359.47"), interest_for(Date.new(2026, 1, 1), Date.new(2026, 2, 1), :thirty_360, :annual)
  end

  # The day count measures the period; the compounding turns the measure into
  # a charge. 100,000 x ((1 + 0.044/2)^(2 x t) - 1) for each period's t.
  test "half-yearly compounding charges each day count's share of the year" do
    assert_equal BigDecimal("167.08"), interest_for(Date.new(2026, 3, 5), Date.new(2026, 3, 19), :actual_365, :semi_annual),
                 "14 days over 365, as a biweekly lender charges"
    assert_equal BigDecimal("370.33"), interest_for(Date.new(2026, 1, 1), Date.new(2026, 2, 1), :actual_365, :semi_annual),
                 "January is 31 days over 365"
    assert_equal BigDecimal("345.45"), interest_for(Date.new(2028, 2, 1), Date.new(2028, 3, 1), :actual_actual, :semi_annual),
                 "a leap February is 29 days over 366"
    assert_equal BigDecimal("193.62"), interest_for(Date.new(2026, 2, 15), Date.new(2026, 3, 1), :thirty_360, :semi_annual, full_period: false),
                 "a part period on 30/360 is 16 days over 360"
  end

  test "a zero rate or an empty period charges nothing" do
    assert_equal BigDecimal("0"), Loan::AmortizationMath.monthly_rate(0, compounding: :semi_annual)
    assert_equal BigDecimal("0"), interest_for(Date.new(2026, 1, 1), Date.new(2026, 1, 1), :actual_365, :semi_annual)
  end

  test "the payment is sized at the compounded rate" do
    assert_equal BigDecimal("625.13"), first_payment(:semi_annual)
    assert_equal BigDecimal("622.64"), first_payment(:annual)
    assert_equal BigDecimal("627.26"), first_payment(:per_period), "4.40% / 12 sizes a higher payment"
  end

  test "a compounded schedule is level to the last row and ends at zero" do
    result = simulate(:semi_annual)
    payments = result.payments

    assert result.converged?
    assert_equal MONTHS, payments.length
    assert_equal [ BigDecimal("625.13") ], payments[0...-1].map { |row| row[:payment_amount] }.uniq
    assert_equal BigDecimal("0"), payments.last[:ending_balance]
  end

  # Sizing sees the compounding but not the day count: one constant rate keeps
  # the payment level while the charge follows each month's length.
  test "a compounded loan on a day count keeps a level payment" do
    payments = simulate(:semi_annual, convention: :actual_365).payments

    assert_equal [ BigDecimal("625.13") ], payments[0...-1].map { |row| row[:payment_amount] }.uniq
    assert_equal BigDecimal("370.33"), payments.first[:interest_payment], "January charges its 31 days"
  end

  # On a variable loan both rates run through the compounding: the period that
  # straddles a change accrues at the opening rate's compounded factor, and the
  # payment is re-sized once at the new rate's, told what that period charged.
  test "a compounded variable loan re-sizes once across a rate change" do
    change = Date.new(2026, 6, 15)
    rows = Loan::Simulator.new(
      starting_balance: BALANCE,
      accrual_start_date: Date.new(2026, 1, 1),
      payment_schedule: (1..MONTHS).map { |n| Date.new(2026, 1, 1) >> n },
      accrual_rate_for: ->(date) { date < change ? RATE : 6 },
      currency_precision: 2,
      compounding: :semi_annual
    ).run.payments
    straddle = rows.index { |row| row[:payment_date] == Date.new(2026, 7, 1) }
    opening = rows[straddle][:beginning_balance]
    old_rate = Loan::AmortizationMath.monthly_rate(RATE, compounding: :semi_annual)
    new_rate = Loan::AmortizationMath.monthly_rate(6, compounding: :semi_annual)

    assert_equal BigDecimal("625.13"), rows.first[:payment_amount]
    assert_equal (opening * old_rate).round(2), rows[straddle][:interest_payment],
                 "June accrues at the opening 4.40%, compounded half-yearly"
    resized = Loan::AmortizationMath.level_payment(balance: opening, monthly_rate: new_rate,
                                                   remaining_payments: MONTHS - straddle, currency_precision: 2,
                                                   first_period_interest: rows[straddle][:interest_payment])
    assert_equal resized, rows[straddle][:payment_amount], "the re-sized payment covers what June actually charged"
    assert_not_equal Loan::AmortizationMath.level_payment(balance: opening, monthly_rate: BigDecimal("6") / 100 / 12,
                                                          remaining_payments: MONTHS - straddle, currency_precision: 2,
                                                          first_period_interest: rows[straddle][:interest_payment]),
                     resized, "the new rate was sized per period instead of compounded"
    assert_equal [ resized ], rows[straddle...-1].map { |row| row[:payment_amount] }.uniq,
                 "no row after the change is re-sized again"
    assert_equal (rows[straddle + 1][:beginning_balance] * new_rate).round(2), rows[straddle + 1][:interest_payment],
                 "July accrues at 6%, compounded half-yearly"
  end

  # A compounded factor is computed once per rate, compounding and length.
  test "a compounded factor is computed once and then reused" do
    first = Loan::AmortizationMath.monthly_rate(BigDecimal("3.17"), compounding: :semi_annual)
    BigMath.expects(:log).never

    assert_equal first, Loan::AmortizationMath.monthly_rate(BigDecimal("3.17"), compounding: :semi_annual)
    assert_equal first, Loan::AmortizationMath.monthly_rate(BigDecimal("3.170"), compounding: "semi_annual")
  end

  test "an unsupported compounding is refused rather than silently defaulted" do
    error = assert_raises(ArgumentError) { simulate(:quarterly) }
    assert_match(/unsupported compounding/, error.message)

    assert_raises(ArgumentError) do
      Loan::AmortizationMath.monthly_rate(RATE, compounding: :quarterly)
    end
  end

  test "a loan defaults to the compounding that preserves today's arithmetic" do
    assert_equal "per_period", Loan.new.interest_compounding
    assert_equal "per_period", Loan::DEFAULT_INTEREST_COMPOUNDING
  end

  test "the column refuses a compounding the engine does not implement" do
    loan = loans(:one)
    loan.interest_compounding = "quarterly"

    assert_not loan.valid?
    assert_includes loan.errors[:interest_compounding], "is not included in the list"
  end

  # Walks the path a real loan takes -- Loan -> AmortizationSchedule.for ->
  # Simulator -- because the wiring between them is what can silently not be
  # done. Changing the setting must restate the memoised schedule at once.
  test "a loan's stored compounding reaches its schedule" do
    loan = Account.create!(
      family: families(:dylan_family), name: "Half-yearly #{SecureRandom.hex(3)}", balance: BALANCE, currency: "CAD",
      accountable: Loan.create!(subtype: "mortgage", interest_rate: RATE, term_months: MONTHS, rate_type: "fixed",
                                start_date: Date.new(2026, 1, 1), initial_balance: BALANCE,
                                interest_compounding: "semi_annual")
    ).loan
    stored = Loan.find(loan.id)

    assert_equal BigDecimal("625.13"), stored.amortization_schedule.payments.first.payment.amount
    assert_equal BigDecimal("363.35"), stored.amortization_schedule.payments.first.interest.amount

    stored.interest_compounding = "per_period"

    assert_equal BigDecimal("627.26"), stored.amortization_schedule.payments.first.payment.amount,
                 "the schedule was answered from a memo built on the old compounding"
  end

  # The ledger replay (#4470) charges each period with the same factor as the
  # schedule. 20,000 at 12% compounded half-yearly: 20,000 x (1.06^(1/6) - 1).
  test "the ledger replay charges the loan's compounding" do
    account = create_loan_account(interest_compounding: "semi_annual", entries: [
      { type: "opening_anchor", date: Date.new(2026, 1, 1), balance: 20_000 },
      { type: "transaction", date: Date.new(2026, 2, 1), amount: -2_000 }
    ])

    change = principal_payments(account).change_for(Date.new(2026, 2, 1))

    assert_equal BigDecimal("195.18"), change.interest_paid
    assert_equal BigDecimal("1804.82"), change.principal_paid
  end

  test "paying a compounded schedule replays onto the schedule's balance" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, interest_compounding: "semi_annual",
                                  day_count_convention: "actual_365", entries: [
      { type: "opening_anchor", date: Date.new(2026, 1, 1), balance: 12_000 }
    ])
    instalments = account.loan.amortization_schedule.payments.first(6)
    instalments.each do |instalment|
      account.entries.create!(name: "Payment", date: instalment.date, amount: -instalment.payment.amount,
                              currency: account.currency, entryable: Transaction.new)
    end
    account.reload

    changes = principal_payments(account).changes.values

    assert_equal instalments.sum(BigDecimal("0")) { |row| row.interest.amount }, changes.sum(BigDecimal("0"), &:interest_paid)
    assert_equal instalments.last.ending_balance.amount,
                 BigDecimal("12000") - changes.sum(BigDecimal("0"), &:principal_paid)
  end

  private
    def principal_payments(account)
      Loan::PrincipalPayments.for(account.loan, entries: Balance::SyncCache.new(account).entries)
    end

    def interest_for(from, to, convention, compounding, full_period: true)
      factor = Loan::AmortizationMath.accrual_factor(
        annual_percentage: RATE, period_start: from, period_end: to,
        day_count_convention: convention, full_period: full_period, compounding: compounding
      )
      (BigDecimal(BALANCE.to_s) * factor).round(2)
    end

    def first_payment(compounding)
      simulate(compounding).payments.first[:payment_amount]
    end

    def simulate(compounding, convention: :thirty_360)
      Loan::Simulator.new(
        starting_balance: BALANCE,
        accrual_start_date: Date.new(2026, 1, 1),
        payment_schedule: (1..MONTHS).map { |n| Date.new(2026, 1, 1) >> n },
        accrual_rate_for: ->(_date) { RATE },
        currency_precision: 2,
        day_count_convention: convention,
        compounding: compounding
      ).run
    end
end
