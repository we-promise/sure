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

    def scheduled_balance_at(loan, date)
      loan.amortization_schedule.payments
        .select { |p| p.date <= date }.last.ending_balance.amount
    end
end
