require "test_helper"

# A lender accrues interest on a stated basis, and `actual/365` -- standard for
# UK and Australian mortgages -- charges by the length of the month. Charging
# every period as a flat 1/12 cannot express that, so a borrower's statement
# and the app disagree on every row.
#
# The load-bearing test here is not any of the `actual/365` figures. It is that
# the DEFAULT still charges exactly what it charged before: this engine is the
# single accrual point for every loan figure in the product, so a default that
# moved would silently restate every schedule.
class Loan::DayCountConventionTest < ActiveSupport::TestCase
  BALANCE = 300_000
  RATE = 6

  # 300,000 at 6% is 18,000 a year, so each figure below is 18,000 x days/denominator.
  # Computed by hand from the convention, not read back out of the engine.
  test "actual/365 charges by the length of the month" do
    assert_equal BigDecimal("1528.77"), interest_for(Date.new(2026, 1, 1), Date.new(2026, 2, 1), :actual_365),
                 "January is 31 days: 18000 x 31/365"
    assert_equal BigDecimal("1380.82"), interest_for(Date.new(2026, 2, 1), Date.new(2026, 3, 1), :actual_365),
                 "February is 28 days: 18000 x 28/365"
    assert_equal BigDecimal("1479.45"), interest_for(Date.new(2026, 4, 1), Date.new(2026, 5, 1), :actual_365),
                 "April is 30 days: 18000 x 30/365"
  end

  # The leap day is the residue that does not cancel over a year, and the two
  # actual conventions part company on it: actual/365 charges a 366th day at
  # the same daily rate, actual/actual spreads the year over 366.
  test "the two actual conventions differ on a leap February" do
    assert_equal BigDecimal("1430.14"), interest_for(Date.new(2028, 2, 1), Date.new(2028, 3, 1), :actual_365),
                 "29 days over 365"
    assert_equal BigDecimal("1426.23"), interest_for(Date.new(2028, 2, 1), Date.new(2028, 3, 1), :actual_actual),
                 "29 days over 366"
  end

  # 30/360 reduces to 1/12 exactly, which is the whole reason it is the default.
  test "the default charges a flat twelfth, whatever the month holds" do
    %w[2026-01-01 2026-02-01 2026-04-01 2028-02-01].each do |iso|
      from = Date.parse(iso)
      assert_equal BigDecimal("1500"), interest_for(from, from >> 1, :thirty_360),
                   "#{iso} should charge 18000/12 regardless of month length"
    end
  end

  test "an unspecified convention is the default one" do
    from = Date.new(2026, 2, 1)

    assert_equal interest_for(from, from >> 1, :thirty_360), interest_for(from, from >> 1, nil)
  end

  # The negative test the whole change rests on. `Loan::Simulator` is the single
  # accrual point upstream -- `Loan::AmortizationSchedule` runs through it -- so
  # a default that charged anything other than a flat 1/12 would restate every
  # existing schedule. Row for row, not merely in total.
  test "a default loan produces the schedule it produced before, row for row" do
    schedule = (1..12).map { |n| Date.new(2026, 1, 1) >> n }

    baseline = simulate(schedule: schedule, convention: nil)
    explicit = simulate(schedule: schedule, convention: :thirty_360)

    assert_equal 12, baseline.payments.length
    baseline.payments.zip(explicit.payments).each_with_index do |(was, now), index|
      assert_equal was, now, "period #{index + 1} moved between the implicit and explicit default"
    end

    # And against the arithmetic itself, so the test does not merely compare the
    # engine with itself: every period is the flat twelfth on its opening balance.
    baseline.payments.each_with_index do |payment, index|
      opening = index.zero? ? BigDecimal(BALANCE.to_s) : baseline.payments[index - 1][:ending_balance]
      assert_equal (opening * BigDecimal(RATE.to_s) / 100 / 12).round(2), payment[:interest_payment],
                   "period #{index + 1} is not a flat twelfth of the opening balance"
    end
  end

  # The design decision that keeps the payment level. `level_payment` is an
  # annuity formula over one constant periodic rate; if the day count reached
  # the sizing, the rate would differ every month and :reamortize would rebuild
  # the payment every period. The charge varies, the contracted payment does not.
  test "a varying day count does not resize the payment every period" do
    schedule = (1..12).map { |n| Date.new(2026, 1, 1) >> n }

    result = simulate(schedule: schedule, convention: :actual_365)
    # The final period settles the balance, so its amount legitimately differs;
    # every period before it is the contracted payment.
    contracted = result.payments[0...-1].map { |p| p[:payment_amount] }.uniq

    assert_equal 1, contracted.length,
                 "the payment was resized as the month length changed: #{contracted.inspect}"

    # And it is the SAME payment the default sizes, because sizing never sees
    # the day count. If the straddle correction (`first_period_interest`) were
    # keyed on the derived factors rather than on the rates, a constant-rate
    # loan would look like a rate change every month and this would move.
    default_payment = simulate(schedule: schedule, convention: :thirty_360).payments.first[:payment_amount]
    assert_equal default_payment, contracted.first,
                 "the day count reached the payment sizing"
  end

  test "an unsupported convention is refused rather than silently defaulted" do
    error = assert_raises(ArgumentError) do
      simulate(schedule: [ Date.new(2026, 2, 1) ], convention: :actual_360)
    end

    assert_match(/unsupported day-count convention/, error.message)
  end

  # The column is worthless if it does not reach the engine. This walks the
  # whole path a real loan takes -- Loan -> AmortizationSchedule.for ->
  # Simulator -- rather than constructing the engine directly, because the
  # wiring between them is the part that can silently not be done.
  test "a loan's stored convention reaches the schedule it produces" do
    loan = loans(:one)
    loan.account.update!(currency: "USD")
    loan.update!(day_count_convention: "thirty_360")

    default_first = loan.amortization_schedule.payments.first.interest.amount

    loan.update!(day_count_convention: "actual_365")
    actual_first = loan.amortization_schedule.payments.first.interest.amount

    assert_not_equal default_first, actual_first,
                     "changing the loan's convention did not change its schedule"
  end

  test "the column refuses a convention the engine does not implement" do
    loan = loans(:one)

    loan.day_count_convention = "actual_360"
    assert_not loan.valid?
    assert_includes loan.errors[:day_count_convention], "is not included in the list"
  end

  test "a loan defaults to the convention that preserves today's arithmetic" do
    assert_equal "thirty_360", Loan.new.day_count_convention
    assert_equal "thirty_360", Loan::DEFAULT_DAY_COUNT_CONVENTION
  end

  private
    def simulate(schedule:, convention:, balance: BALANCE, rate: RATE)
      Loan::Simulator.new(
        starting_balance: balance,
        accrual_start_date: schedule.first - 31,
        payment_schedule: schedule,
        accrual_rate_for: ->(_date) { rate },
        currency_precision: 2,
        day_count_convention: convention
      ).run
    end

    # One period, so the figure asserted is the charge for exactly that span.
    def interest_for(from, to, convention)
      Loan::Simulator.new(
        starting_balance: BALANCE,
        accrual_start_date: from,
        payment_schedule: [ to ],
        accrual_rate_for: ->(_date) { RATE },
        currency_precision: 2,
        day_count_convention: convention
      ).run.payments.first[:interest_payment]
    end
end
