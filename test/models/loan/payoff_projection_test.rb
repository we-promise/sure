require "test_helper"

class Loan::PayoffProjectionTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @today = Date.new(2027, 1, 15)
  end

  test "a loan exactly on contract projects the schedule it is already on" do
    loan = build_loan(term_months: 24)
    on_contract = scheduled_balance_at(loan, @today)
    loan.account.update!(balance: on_contract)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.applicable?
    assert projection.converged?
    assert_equal loan.amortization_schedule.payoff_date, projection.payoff_date
    assert_equal 0, projection.months_saved
  end

  # Extra payments already made need no input of their own: they are why the
  # recorded balance sits below the scheduled one, and the projection starts
  # from that balance (#100, decision 10).
  test "an overpaid loan finishes early and pays less interest, with no extra-payment input" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 50_000)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.converged?
    assert_operator projection.months_saved, :>, 0
    assert_operator projection.interest_saved.amount, :>, 0
    assert_operator projection.payoff_date, :<, loan.amortization_schedule.payoff_date
  end

  # Decision 1 on #100. A variable loan that is ahead keeps paying what the
  # contract currently asks and therefore finishes early. Re-amortising the
  # smaller balance would shrink the repayment and land it back on the
  # original maturity, which is what this test exists to refuse.
  test "a variable loan ahead of schedule pays the contract's repayment and finishes early" do
    loan = build_loan(term_months: 24, rate_type: "variable")
    loan.update!(variable_rate_schedule: { Date.new(2026, 7, 1).iso8601 => "12.0" })
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 30_000)
    loan.reload

    projection = loan.payoff_projection(as_of: @today)
    schedule_by_date = loan.amortization_schedule.payments.index_by(&:date)

    projection.payments[0..-2].each do |payment|
      assert_equal schedule_by_date.fetch(payment[:payment_date]).payment.amount, payment[:payment_amount],
        "on #{payment[:payment_date]} the projection must pay what the contract asks, not a re-sized figure"
    end
    assert_operator projection.payoff_date, :<, loan.amortization_schedule.payoff_date
    assert_operator projection.months_saved, :>, 0
  end

  # A variable loan's CONTRACT resizes the repayment at each rate change, and
  # the projection follows the schedule's own resized figure -- not one
  # re-derived from the balance in front of it.
  test "a future recorded rate change moves the projected repayment by the schedule's amount" do
    loan = build_loan(term_months: 24, rate_type: "variable")
    change_date = @today >> 3
    loan.update!(variable_rate_schedule: { change_date.iso8601 => "18.0" })
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 20_000)
    loan.reload

    projection = loan.payoff_projection(as_of: @today)
    schedule_by_date = loan.amortization_schedule.payments.index_by(&:date)
    first_resized = projection.payments.find { |p| p[:payment_date] >= change_date }

    assert_operator first_resized[:payment_amount], :>, projection.payments.first[:payment_amount],
      "the repayment must resize when the recorded rate rises"
    assert_equal schedule_by_date.fetch(first_resized[:payment_date]).payment.amount, first_resized[:payment_amount],
      "and it resizes to the schedule's figure, not to one sized from the smaller balance"
  end

  # On a fixed loan every scheduled row carries the same repayment, so paying
  # the schedule's rows is the held contracted payment. Byte-identical to a
  # :hold run seeded with that payment, which pins that decision 1 changed
  # nothing for fixed loans.
  test "a fixed loan's projection is identical to holding the contracted payment" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 10_000)
    loan.reload
    projection = loan.payoff_projection(as_of: @today)
    schedule = loan.amortization_schedule
    remaining = schedule.payments.select { |p| p.date > @today }
    resolver = Loan::RateResolver.for(loan)

    held = Loan::Simulator.new(
      starting_balance: loan.account.balance,
      accrual_start_date: @today,
      payment_schedule: remaining.map(&:date),
      accrual_rate_for: resolver.method(:accrual_rate_for),
      re_amortisation_events: resolver.method(:re_amortisation_events),
      payment_amount: remaining.first.payment.amount,
      payment_strategy: :hold,
      currency_precision: 2,
      settle_at_schedule_end: false
    ).run

    assert_equal held.payments, projection.payments
  end

  # The case that was unreachable in #103, and the reason convergence came back
  # with this change. A borrower far enough behind is not paying the loan off on
  # the contracted repayment -- and must not be shown a payoff date implying
  # otherwise.
  test "a loan too far behind to clear reports a balloon and no payoff date" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: 400_000)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.applicable?
    assert_not projection.converged?
    assert_nil projection.payoff_date
    assert_operator projection.balloon_amount.amount, :>, 0
    assert_equal 0, projection.months_saved, "no months are saved by a loan that never finishes"
  end

  # CodeRabbit on #3474: `accounts.balance` is nullable and Money.new(nil)
  # raises, and the Schedule tab reads the projection outside the chart's
  # rescue. A loan with no balance yet has nothing to project.
  test "a loan with no balance yet is not applicable rather than raising" do
    loan = build_loan(term_months: 24)
    loan.account.update_columns(balance: nil)

    projection = loan.payoff_projection(as_of: @today)

    assert_not projection.applicable?
    assert_nil projection.payoff_date
    assert_equal 0, projection.current_balance.amount
  end

  # The projection pays the contract's own repayment and never
  # settles early, so it converges only when today's balance is at or below
  # the contract's. A converged projection therefore never adds interest, which
  # is why the chart has no "additional interest" card.
  test "a loan even slightly behind does not converge, so a converged projection never adds interest" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today) + 500)

    projection = loan.payoff_projection(as_of: @today)

    assert projection.applicable?
    assert_not projection.converged?
    assert_nil projection.payoff_date
    assert_operator projection.balloon_amount.amount, :>, 0
  end

  test "is not applicable to a loan with no schedule or nothing left to owe" do
    unamortizable = build_loan(term_months: 24, rate_type: "")
    assert_not unamortizable.payoff_projection(as_of: @today).applicable?

    cleared = build_loan(term_months: 24)
    cleared.account.update!(balance: 0)
    assert_not cleared.payoff_projection(as_of: @today).applicable?

    matured = build_loan(term_months: 24)
    assert_not matured.payoff_projection(as_of: Date.new(2040, 1, 1)).applicable?
  end


  # A variable loan's CONTRACT resizes the repayment at each rate change.
  # Holding one figure to maturity projects a repayment the lender will never
  # ask for, and the further out the change, the more wrong the payoff date.
  test "a variable projection re-amortises at a recorded rate change" do
    loan = build_loan(term_months: 24, rate_type: "variable")
    loan.update!(variable_rate_schedule: { (@today >> 3).iso8601 => "18.0" })
    loan.account.update!(balance: scheduled_balance_at(loan, @today))
    projection = loan.reload.payoff_projection(as_of: @today)

    before = projection.payments.first[:payment_amount]
    after = projection.payments.find { |p| p[:payment_date] >= (@today >> 3) }[:payment_amount]

    assert_operator after, :>, before,
      "the repayment must resize when the recorded rate rises"
  end

  # The comparison the cards quote: a balance recorded on a scheduled date,
  # equal to the schedule's balance for that date, saves nothing. The
  # projection's first period then charges exactly what the schedule's next
  # row charges, so `interest_saved` is zero, not merely small.
  test "a loan exactly on contract saves no interest" do
    loan = build_loan(term_months: 24)
    on_date = loan.amortization_schedule.payments.find { |p| p.date > @today }.date
    loan.account.update!(balance: loan.amortization_schedule.payments.find { |p| p.date == on_date }.ending_balance.amount)

    projection = loan.reload.payoff_projection(as_of: on_date)

    assert_equal 0, projection.months_saved
    assert_equal BigDecimal("0"), projection.interest_saved.amount
  end

  # Under monthly accrual a period is charged at the rate in force when it
  # OPENED (Loan::Simulator's class comment), so a change recorded between the
  # last payment and today belongs to the next period. Opening the projection's
  # first period at `as_of` instead re-rated the month already running, and a
  # variable borrower exactly on contract was quoted interest the schedule
  # never charges.
  test "a rate change between the last payment and today does not re-rate the month already running" do
    loan = build_loan(term_months: 24, rate_type: "variable")
    last_paid = loan.amortization_schedule.payments.select { |p| p.date <= @today }.last.date
    change_date = last_paid + 5
    assert_operator change_date, :<, @today, "the change must fall inside the period already running"

    loan.update!(variable_rate_schedule: { change_date.iso8601 => "12.0" })
    # Fresh records: the schedule read above is memoised without the change.
    loan.account.update!(balance: scheduled_balance_at(Loan.find(loan.id), @today))
    projection = Loan.find(loan.id).payoff_projection(as_of: @today)

    assert projection.converged?
    assert_equal 0, projection.months_saved
    assert_equal BigDecimal("0"), projection.interest_saved.amount,
      "on contract, the projection must charge the running month what the schedule charges it"
  end

  # The extra rides on top of the contract's repayment in every period, so
  # each period pays exactly the extra more than the same loan without it.
  # The last row settles the balance and is the one exception.
  test "a monthly extra adds to every period's repayment" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today))

    baseline = loan.payoff_projection(as_of: @today)
    with_extra = loan.payoff_projection(as_of: @today, extra: 1_000)

    assert_operator with_extra.payments.length, :>, 1
    with_extra.payments[0..-2].each_with_index do |payment, index|
      assert_equal BigDecimal("1000"), payment[:payment_amount] - baseline.payments[index][:payment_amount],
        "period #{index + 1} must pay the extra on top of the contract's repayment"
    end
  end

  # Months sooner and interest saved are measured against the same loan paying
  # no extra, not against the contract. On an overpaid loan the two differ, so
  # comparing against the contract would fold in how far ahead the borrower
  # already is.
  test "the extra clears the loan sooner, and saves interest against no extra" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 50_000)

    baseline = loan.payoff_projection(as_of: @today)
    with_extra = loan.payoff_projection(as_of: @today, extra: 5_000)

    # The first period by hand: 6% a year is 0.5% a month on the balance the
    # period opened with, and the payment is the contract's plus the extra.
    opening = loan.account.balance
    first = with_extra.payments.first
    expected_interest = (opening * BigDecimal("0.005")).round(2)
    assert_equal expected_interest, first[:interest_payment]
    assert_equal baseline.payments.first[:payment_amount] + 5_000 - expected_interest, first[:principal_payment]

    assert_equal baseline.payments.length - with_extra.payments.length, with_extra.months_sooner_than(baseline)
    assert_operator with_extra.months_sooner_than(baseline), :>, 0
    saved = baseline.total_interest.amount - with_extra.total_interest.amount
    assert_equal Money.new(saved, "USD"), with_extra.interest_saved_versus(baseline)
    assert_operator saved, :>, 0
    assert_not_equal with_extra.interest_saved, with_extra.interest_saved_versus(baseline),
      "against no extra, not against the contract: this loan was already ahead"
  end

  # A baseline that never clears has no payoff date, so there is no "sooner"
  # to quote and no comparable total interest. Nor is there for an extra that
  # does not clear the loan either.
  test "a baseline that never clears quotes no months sooner or interest saved" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: 400_000)

    baseline = loan.payoff_projection(as_of: @today)
    clearing = loan.payoff_projection(as_of: @today, extra: 20_000)
    too_small = loan.payoff_projection(as_of: @today, extra: 10)

    assert_not baseline.converged?
    assert clearing.converged?, "an extra this large clears the loan"
    assert clearing.payoff_date
    assert_nil clearing.months_sooner_than(baseline)
    assert_nil clearing.interest_saved_versus(baseline)

    assert_not too_small.converged?
    assert_nil too_small.months_sooner_than(baseline)
    assert_nil too_small.interest_saved_versus(baseline)
  end

  # Weekly extras are dated, starting the day after as_of, and each period is
  # credited with the extras falling in (previous payment date, payment date].
  # Payments land on the 1st and as_of is Friday 15 January 2027, so the
  # extras fall on Saturdays from the 16th: three before 1 February, then four,
  # four, and five before 1 May. The fifth is on 1 May itself, so a payment
  # date belongs to the period it closes.
  test "a weekly extra credits each date in its period" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today))

    baseline = loan.payoff_projection(as_of: @today)
    weekly = loan.payoff_projection(as_of: @today, extra: 100, extra_frequency: "weekly")

    assert_equal [ 3, 4, 4, 5, 4 ], extra_counts(weekly, baseline, 100).first(5)
  end

  # The first dated extra is the day after as_of, never as_of itself: that
  # day's period is already open. With as_of the day before a payment, the
  # first extra lands on the payment date, so that period carries exactly one.
  test "the first weekly extra falls the day after as_of" do
    as_of = Date.new(2027, 1, 31)
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, as_of))

    baseline = loan.payoff_projection(as_of: as_of)
    weekly = loan.payoff_projection(as_of: as_of, extra: 100, extra_frequency: "weekly")

    assert_equal 1, extra_counts(weekly, baseline, 100).first, "1 February, the day after as_of, is in the first period"
  end

  # Every fourteen days from the 16th: two in most periods, three in the
  # period that closes on 1 August (3, 17 and 31 July).
  test "a fortnightly extra credits two or three times a period" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today))

    baseline = loan.payoff_projection(as_of: @today)
    fortnightly = loan.payoff_projection(as_of: @today, extra: 100, extra_frequency: "fortnightly")

    assert_equal [ 2, 2, 2, 2, 2, 2, 3 ], extra_counts(fortnightly, baseline, 100).first(7)
  end

  test "monthly is the default, one extra in every period" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today))

    default = loan.payoff_projection(as_of: @today, extra: 100)
    monthly = loan.payoff_projection(as_of: @today, extra: 100, extra_frequency: "monthly")

    assert_equal default.payments, monthly.payments
  end

  # A programming error, not user input: Loan::ExtraRepayment refuses an
  # unknown frequency before it reaches the projection.
  test "an unknown frequency is refused" do
    loan = build_loan(term_months: 24)

    error = assert_raises(ArgumentError) { loan.payoff_projection(as_of: @today, extra: 100, extra_frequency: "daily") }
    assert_equal "Unknown extra frequency: \"daily\"", error.message
  end

  test "no extra leaves the projection identical" do
    loan = build_loan(term_months: 24)
    loan.account.update!(balance: scheduled_balance_at(loan, @today) - 10_000)

    baseline = loan.payoff_projection(as_of: @today)

    [ nil, 0 ].each do |extra|
      projection = loan.payoff_projection(as_of: @today, extra: extra)
      assert_equal baseline.payments, projection.payments, "extra: #{extra.inspect}"
      assert_equal 0, projection.months_sooner_than(baseline)
      assert_equal Money.new(0, "USD"), projection.interest_saved_versus(baseline)
    end
  end

  private
    # Built the way the account form builds one: with an opening valuation for
    # the amount borrowed. `Loan#original_balance` reads it; without it the
    # principal follows whatever the current balance is later set to, and a
    # schedule read after a balance update would amortise a different loan.
    def build_loan(term_months:, rate_type: "fixed", interest_rate: 6)
      account = Account.create!(
        family: @family, name: "Loan #{SecureRandom.hex(4)}",
        balance: 500_000, currency: "USD",
        accountable: Loan.new(subtype: "mortgage", interest_rate: interest_rate,
                              term_months: term_months, rate_type: rate_type,
                              start_date: Date.new(2026, 1, 1))
      )
      account.entries.create!(
        date: Date.new(2026, 1, 1), name: "Opening balance", amount: 500_000, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor")
      )
      account.loan
    end

    # How many extras each period carried: its payment above the same loan's
    # without the extra, in units of the extra. The last row settles the
    # balance and is left out.
    def extra_counts(projection, baseline, extra)
      projection.payments[0..-2].each_with_index.map do |payment, index|
        ((payment[:payment_amount] - baseline.payments[index][:payment_amount]) / extra).to_i
      end
    end

    def scheduled_balance_at(loan, date)
      loan.amortization_schedule.payments
        .select { |p| p.date <= date }.last.ending_balance.amount
    end
end
