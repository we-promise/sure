require "test_helper"

class Loan::PrincipalPaymentsTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  OPENING_DATE = Date.new(2026, 1, 1)
  PAYMENT_DATE = Date.new(2026, 2, 1)

  test "an unlinked payment pays interest before principal" do
    account = create_loan_account(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -2_000 }
    ])

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("1800"), change.principal_paid
    assert_equal BigDecimal("200"), change.interest_paid
    assert_equal BigDecimal("0"), change.principal_added
    assert_equal BigDecimal("-1800"), change.net
  end

  test "a payment below accrued interest does not reduce principal" do
    account = create_loan_account(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -100 }
    ])

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("0"), change.principal_paid
    assert_equal BigDecimal("100"), change.interest_paid
    assert_equal BigDecimal("0"), change.net
  end

  test "a payment above interest reduces principal by the excess" do
    account = create_loan_account(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -5_000 }
    ])

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("4800"), change.principal_paid
    assert_equal BigDecimal("200"), change.interest_paid
  end

  test "later payments accrue interest on the reduced principal" do
    account = create_loan_account(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -10_000 },
      { type: "transaction", date: Date.new(2026, 3, 2), amount: -2_000 }
    ])

    payments = principal_payments(account)

    assert_equal BigDecimal("9800"), payments.change_for(PAYMENT_DATE).principal_paid
    assert_equal BigDecimal("1898"), payments.change_for(Date.new(2026, 3, 2)).principal_paid
    assert_equal BigDecimal("102"), payments.change_for(Date.new(2026, 3, 2)).interest_paid
  end

  test "unpaid interest carries into the next payment" do
    account = create_loan_account(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -100 },
      { type: "transaction", date: Date.new(2026, 3, 2), amount: -2_000 }
    ])

    payments = principal_payments(account)

    assert_equal BigDecimal("0"), payments.change_for(PAYMENT_DATE).principal_paid
    assert_equal BigDecimal("100"), payments.change_for(PAYMENT_DATE).interest_paid
    assert_equal BigDecimal("1700"), payments.change_for(Date.new(2026, 3, 2)).principal_paid
    assert_equal BigDecimal("300"), payments.change_for(Date.new(2026, 3, 2)).interest_paid
  end

  test "uses the loan's day-count convention" do
    account = create_loan_account(day_count_convention: "actual_365", entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -2_000 }
    ])

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("203.84"), change.interest_paid
    assert_equal BigDecimal("1796.16"), change.principal_paid
  end

  test "a positive line adds principal instead of paying interest" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: 100 },
      { type: "transaction", date: PAYMENT_DATE, amount: -1_066.19 }
    ])

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("100"), change.principal_added, "a positive row is a charge or a refund, never interest"
    assert_equal BigDecimal("120"), change.interest_paid
    assert_equal BigDecimal("946.19"), change.principal_paid
  end

  test "a refund raises the balance and does not become interest" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -1_066.19 },
      { type: "transaction", date: Date.new(2026, 2, 15), amount: 500 },
      { type: "transaction", date: Date.new(2026, 3, 1), amount: -1_066.19 }
    ])

    payments = principal_payments(account)
    refund = payments.change_for(Date.new(2026, 2, 15))
    next_payment = payments.change_for(Date.new(2026, 3, 1))

    assert_equal BigDecimal("500"), refund.principal_added
    assert_equal BigDecimal("0"), refund.interest_paid
    assert_equal BigDecimal("110.54"), next_payment.interest_paid,
                 "the next period charges interest on the period's opening principal, not the refund"
    assert_equal BigDecimal("955.65"), next_payment.principal_paid
  end

  test "a late principal-only transfer pays the period it missed" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000,
                                  principal_only_transfers: true, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    instalment = account.loan.amortization_schedule.payments.first

    create_linked_loan_payment(account, instalment.principal.amount, instalment.date + 4.days)
    account.reload

    change = principal_payments(account).change_for(instalment.date + 4.days)

    assert_equal BigDecimal("946.19"), change.principal_paid
    assert_equal BigDecimal("120"), change.interest_paid
  end

  test "an early full payment pays the coming period's interest" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    instalment = account.loan.amortization_schedule.payments.first

    account.entries.create!(name: "Payment", date: instalment.date - 10.days,
                            amount: -instalment.payment.amount,
                            currency: account.currency, entryable: Transaction.new)
    account.reload

    change = principal_payments(account).change_for(instalment.date - 10.days)

    assert_equal BigDecimal("946.19"), change.principal_paid
    assert_equal BigDecimal("120"), change.interest_paid
  end

  test "a payment above the remaining principal leaves a credit" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -20_000 }
    ])

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("19_880"), change.principal_paid
    assert_equal BigDecimal("120"), change.interest_paid
    assert_equal BigDecimal("-19_880"), change.net
    assert_equal BigDecimal("-7_880"), BigDecimal("12_000") + change.net
  end

  test "a linked transfer is a payment, not interest" do
    account = create_loan_account(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 }
    ])

    create_linked_loan_payment(account, 2_000, PAYMENT_DATE)
    account.reload

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("1800"), change.principal_paid, "a transfer that is not the scheduled principal is split"
    assert_equal BigDecimal("200"), change.interest_paid
  end

  test "a linked transfer equal to the scheduled principal is a full payment without the opt-in" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    instalment = account.loan.amortization_schedule.payments.first

    create_linked_loan_payment(account, instalment.principal.amount, instalment.date)
    account.reload

    change = principal_payments(account).change_for(instalment.date)

    assert_equal BigDecimal("826.19"), change.principal_paid,
                 "without the opt-in the transfer pays the period's interest first"
    assert_equal BigDecimal("120"), change.interest_paid
  end

  test "a linked transfer is principal-only when the loan opts in" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000,
                                  principal_only_transfers: true, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    instalment = account.loan.amortization_schedule.payments.first

    create_linked_loan_payment(account, instalment.principal.amount - BigDecimal("0.01"), instalment.date)
    account.reload

    change = principal_payments(account).change_for(instalment.date)

    assert_equal BigDecimal("946.18"), change.principal_paid,
                 "a cent away from the scheduled principal is still principal-only"
    assert_equal BigDecimal("120"), change.interest_paid, "the interest was paid as a separate expense"
  end

  test "a linked full EMI is split into interest and principal" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    instalment = account.loan.amortization_schedule.payments.first

    create_linked_loan_payment(account, instalment.payment.amount, instalment.date)
    account.reload

    change = principal_payments(account).change_for(instalment.date)

    assert_equal BigDecimal("946.19"), change.principal_paid
    assert_equal BigDecimal("120"), change.interest_paid
  end

  test "paying the scheduled EMI matches the schedule row for row" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    schedule = account.loan.amortization_schedule
    instalments = schedule.payments.first(3)

    instalments.each do |instalment|
      account.entries.create!(name: "Payment", date: instalment.date,
                              amount: -instalment.payment.amount,
                              currency: account.currency, entryable: Transaction.new)
    end
    account.reload

    payments = principal_payments(account)
    principal_paid = payments.changes.values.sum(BigDecimal("0"), &:principal_paid)
    interest_paid = payments.changes.values.sum(BigDecimal("0"), &:interest_paid)

    assert_equal instalments.sum(BigDecimal("0")) { |payment| payment.principal.amount }, principal_paid
    assert_equal instalments.sum(BigDecimal("0")) { |payment| payment.interest.amount }, interest_paid
    assert_equal instalments.last.ending_balance.amount, BigDecimal("12_000") - principal_paid
  end

  test "an unlinked redraw raises principal for later interest" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -1_066.19 },
      { type: "transaction", date: Date.new(2026, 2, 15), amount: 5_000 },
      { type: "transaction", date: Date.new(2026, 3, 1), amount: -2_000 }
    ])

    payments = principal_payments(account)

    assert_equal BigDecimal("5000"), payments.change_for(Date.new(2026, 2, 15)).principal_added
    assert_equal BigDecimal("0"), payments.change_for(Date.new(2026, 2, 15)).interest_paid
    assert_equal BigDecimal("110.54"), payments.change_for(Date.new(2026, 3, 1)).interest_paid
    assert_equal BigDecimal("1889.46"), payments.change_for(Date.new(2026, 3, 1)).principal_paid
  end

  test "a linked drawdown increases principal for later interest" do
    account = create_loan_account(
      subtype: "line_of_credit",
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
        { type: "transaction", date: PAYMENT_DATE, amount: -200 }
      ]
    )

    create_linked_loan_drawdown(account, 5_000, PAYMENT_DATE)
    account.entries.create!(name: "Payment", date: Date.new(2026, 3, 2), amount: -2_000,
                            currency: account.currency, entryable: Transaction.new)
    account.reload

    payments = principal_payments(account)

    assert_equal BigDecimal("5000"), payments.change_for(PAYMENT_DATE).principal_added
    assert_equal BigDecimal("0"), payments.change_for(PAYMENT_DATE).principal_paid
    assert_equal BigDecimal("1750"), payments.change_for(Date.new(2026, 3, 2)).principal_paid
    assert_equal BigDecimal("250"), payments.change_for(Date.new(2026, 3, 2)).interest_paid
  end

  test "a reconciliation resets principal and clears carried interest" do
    account = create_loan_account(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -100 },
      { type: "reconciliation", date: Date.new(2026, 2, 15), balance: 19_000 },
      { type: "transaction", date: Date.new(2026, 3, 2), amount: -2_000 }
    ])

    payments = principal_payments(account)

    assert_equal BigDecimal("0"), payments.change_for(Date.new(2026, 2, 15)).net
    assert_equal BigDecimal("1898.67"), payments.change_for(Date.new(2026, 3, 2)).principal_paid,
                 "interest on the reconciliation balance for the 16-day 30/360 stub"
    assert_equal BigDecimal("101.33"), payments.change_for(Date.new(2026, 3, 2)).interest_paid
  end

  test "a payment on a reconciliation day is counted and the reset applies to later interest" do
    account = create_loan_account(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "reconciliation", date: PAYMENT_DATE, balance: 18_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -2_000 },
      { type: "transaction", date: Date.new(2026, 3, 1), amount: -2_000 }
    ])

    payments = principal_payments(account)
    reset_day = payments.change_for(PAYMENT_DATE)
    next_day = payments.change_for(Date.new(2026, 3, 1))

    assert_equal BigDecimal("1800"), reset_day.principal_paid
    assert_equal BigDecimal("200"), reset_day.interest_paid
    assert_equal BigDecimal("1820"), next_day.principal_paid, "interest accrues on the reconciliation balance"
    assert_equal BigDecimal("180"), next_day.interest_paid
  end

  test "an insurance premium never reduces principal" do
    account = create_loan_account(
      term_months: 12,
      initial_balance: 12_000,
      insurance_rate: 1.2,
      insurance_rate_type: "level_term",
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
      ]
    )
    instalment = account.loan.amortization_schedule.payments.first
    premium = account.loan.insurance.premium_for(instalment.number).amount.amount

    account.entries.create!(name: "Payment", date: instalment.date,
                            amount: -(instalment.payment.amount + premium),
                            currency: account.currency, entryable: Transaction.new)
    account.reload

    change = principal_payments(account).change_for(instalment.date)

    assert_equal BigDecimal("946.19"), change.principal_paid
    assert_equal BigDecimal("120"), change.interest_paid
  end

  test "an underpaid insurance premium does not reduce principal" do
    account = create_loan_account(
      term_months: 12,
      initial_balance: 12_000,
      insurance_rate: 1.2,
      insurance_rate_type: "level_term",
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
      ]
    )
    instalment = account.loan.amortization_schedule.payments.first
    premium = account.loan.insurance.premium_for(instalment.number).amount.amount

    account.entries.create!(name: "Payment", date: instalment.date,
                            amount: -(instalment.payment.amount + premium - BigDecimal("6.19")),
                            currency: account.currency, entryable: Transaction.new)
    account.reload

    change = principal_payments(account).change_for(instalment.date)

    assert_equal BigDecimal("940"), change.principal_paid,
                 "the unpaid part of the premium comes out of principal, not the whole premium"
    assert_equal BigDecimal("120"), change.interest_paid
  end

  test "two half payments cover the insurance premium once" do
    account = create_loan_account(
      term_months: 12,
      initial_balance: 12_000,
      insurance_rate: 1.2,
      insurance_rate_type: "level_term",
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
      ]
    )
    instalment = account.loan.amortization_schedule.payments.first
    premium = account.loan.insurance.premium_for(instalment.number).amount.amount
    total = instalment.payment.amount + premium
    first_half = (total / 2).round(2)
    second_half = total - first_half

    account.entries.create!(name: "Payment 1", date: instalment.date,
                            amount: -first_half, currency: account.currency, entryable: Transaction.new)
    account.entries.create!(name: "Payment 2", date: instalment.date,
                            amount: -second_half, currency: account.currency, entryable: Transaction.new)
    account.reload

    change = principal_payments(account).change_for(instalment.date)

    assert_equal BigDecimal("946.19"), change.principal_paid
    assert_equal BigDecimal("120"), change.interest_paid
  end

  test "a deferred period charge is not lost after a late payment" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: Date.new(2026, 3, 15), amount: -1_066.19 },
      { type: "transaction", date: Date.new(2026, 4, 1), amount: -1_066.19 }
    ])

    payments = principal_payments(account)

    assert_equal BigDecimal("240"), payments.change_for(Date.new(2026, 3, 15)).interest_paid,
                 "two missed instalments carry 240 of interest"
    assert_equal BigDecimal("826.19"), payments.change_for(Date.new(2026, 3, 15)).principal_paid
    assert_equal BigDecimal("120"), payments.change_for(Date.new(2026, 4, 1)).interest_paid,
                 "the deferred period is still charged on the next due date"
    assert_equal BigDecimal("946.19"), payments.change_for(Date.new(2026, 4, 1)).principal_paid
  end

  test "a payment two days late still matches the schedule for the whole term" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    schedule = account.loan.amortization_schedule
    # SyncCache excludes future entries; replay after the final payment is due.
    travel_to schedule.payments.last.date + 2.days

    schedule.payments.each do |instalment|
      account.entries.create!(name: "Payment", date: instalment.date + 2.days,
                              amount: -instalment.payment.amount,
                              currency: account.currency, entryable: Transaction.new)
    end
    account.reload

    payments = principal_payments(account)
    total_principal = payments.changes.values.sum(BigDecimal("0"), &:principal_paid)
    total_interest = payments.changes.values.sum(BigDecimal("0"), &:interest_paid)

    assert_equal schedule.payments.sum(BigDecimal("0")) { |instalment| instalment.interest.amount }, total_interest
    assert_equal BigDecimal("12_000"), total_principal
  end

  test "an instalment paid in two parts inside the grace window charges the period once" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: Date.new(2026, 2, 1), amount: -600 },
      { type: "transaction", date: Date.new(2026, 2, 2), amount: -466.19 },
      { type: "transaction", date: Date.new(2026, 3, 1), amount: -1_066.19 }
    ])

    payments = principal_payments(account)

    assert_equal BigDecimal("120"), payments.change_for(Date.new(2026, 2, 1)).interest_paid
    assert_equal BigDecimal("480"), payments.change_for(Date.new(2026, 2, 1)).principal_paid
    assert_equal BigDecimal("0"), payments.change_for(Date.new(2026, 2, 2)).interest_paid,
                 "the second part must not pay the next period in advance"
    assert_equal BigDecimal("466.19"), payments.change_for(Date.new(2026, 2, 2)).principal_paid
    assert_equal BigDecimal("110.54"), payments.change_for(Date.new(2026, 3, 1)).interest_paid
    assert_equal BigDecimal("955.65"), payments.change_for(Date.new(2026, 3, 1)).principal_paid
  end

  test "a rate change takes effect from the period that opens on the new rate" do
    account = create_loan_account(
      term_months: 12,
      initial_balance: 12_000,
      rate_type: "variable",
      variable_rate_schedule: { "2026-02-15" => "24.0" },
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
        { type: "transaction", date: Date.new(2026, 4, 1), amount: -2_000 }
      ]
    )

    change = principal_payments(account).change_for(Date.new(2026, 4, 1))

    assert_equal BigDecimal("480"), change.interest_paid,
                 "Jan and Feb charge 12%, then the period opening 1 March charges 24%"
    assert_equal BigDecimal("1520"), change.principal_paid
  end

  test "a loan whose opening anchor differs from its initial balance is left alone" do
    account = create_loan_account(
      term_months: 12,
      initial_balance: 12_000,
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 19_999 }
      ]
    )

    assert_nil principal_payments(account)
  end

  test "paying the schedule for the full term ends at zero" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    schedule = account.loan.amortization_schedule
    # SyncCache excludes future entries; replay after the final payment is due.
    travel_to schedule.payments.last.date

    schedule.payments.each do |instalment|
      account.entries.create!(name: "Payment", date: instalment.date,
                              amount: -instalment.payment.amount,
                              currency: account.currency, entryable: Transaction.new)
    end
    account.reload

    payments = principal_payments(account)
    total_principal = payments.changes.values.sum(BigDecimal("0"), &:principal_paid)
    total_interest = payments.changes.values.sum(BigDecimal("0"), &:interest_paid)

    assert_equal BigDecimal("12_000"), total_principal
    assert_equal schedule.payments.sum(BigDecimal("0")) { |instalment| instalment.interest.amount }, total_interest
    assert_equal BigDecimal("0"), BigDecimal("12_000") - total_principal
  end

  test "a provider loan is left alone" do
    account = create_loan_account(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 }
    ])

    Account.any_instance.stubs(:manual?).returns(false)

    assert_nil Loan::PrincipalPayments.for(account.loan, entries: Balance::SyncCache.new(account).entries)
  end

  test "a loan whose anchor is not its origination is left alone" do
    account = create_loan_account(
      start_date: OPENING_DATE - 1.year,
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 }
      ]
    )

    assert_nil Loan::PrincipalPayments.for(account.loan, entries: Balance::SyncCache.new(account).entries)
  end

  test "a loan without an opening anchor is left alone" do
    account = create_loan_account(entries: [
      { type: "current_anchor", date: Date.current, balance: 20_000 }
    ])

    assert_nil principal_payments(account)
  end

  test "a loan without terms is left alone" do
    account = create_account_with_ledger(
      account: { type: Loan, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 }
      ]
    )

    assert_nil Loan::PrincipalPayments.for(account.loan, entries: Balance::SyncCache.new(account).entries)
  end

  # A term change says what the lender did; the ledger says what the borrower
  # paid. Recorded both ways, the replay lands on the schedule's balance on
  # every due date.
  test "an extra repayment part-way through a period matches the changed schedule" do
    account = loan_with_term_changes([ { effective_date: "2026-03-15", extra_repayment: "2000" } ])
    pay_schedule(account)
    create_linked_loan_payment(account, 2_000, Date.new(2026, 3, 15))

    assert_replay_matches_schedule account
  end

  test "an extra repayment inside the grace window matches the changed schedule" do
    account = loan_with_term_changes([ { effective_date: "2026-03-03", extra_repayment: "2000" } ])
    pay_schedule(account)
    create_linked_loan_payment(account, 2_000, Date.new(2026, 3, 3))

    assert_replay_matches_schedule account
  end

  test "an extra repayment on a due date matches the changed schedule" do
    account = loan_with_term_changes([ { effective_date: "2026-04-01", extra_repayment: "2000" } ])
    pay_schedule(account)
    create_linked_loan_payment(account, 2_000, Date.new(2026, 4, 1))

    assert_replay_matches_schedule account
  end

  test "an extra repayment with the old payment matches the shortened schedule" do
    account = loan_with_term_changes([
      { effective_date: "2026-03-15", extra_repayment: "2000", payment: "1066.19" }
    ])
    pay_schedule(account)
    create_linked_loan_payment(account, 2_000, Date.new(2026, 3, 15))

    assert_equal 10, account.loan.amortization_schedule.payments.size
    assert_replay_matches_schedule account
  end

  test "principal-only transfers and an extra repayment match the changed schedule" do
    [ "2026-03-15", "2026-03-03", "2026-04-01" ].each do |effective_date|
      account = loan_with_term_changes(
        [ { effective_date: effective_date, extra_repayment: "2000" } ], principal_only_transfers: true
      )
      account.loan.amortization_schedule.payments.each do |instalment|
        create_linked_loan_payment(account, instalment.principal.amount, instalment.date)
      end
      create_linked_loan_payment(account, 2_000, Date.iso8601(effective_date))

      assert_replay_matches_schedule account, "extra repayment on #{effective_date}"
    end
  end

  test "an extra repayment on a variable loan matches the changed schedule" do
    account = loan_with_term_changes(
      [ { effective_date: "2026-03-15", extra_repayment: "2000" }, { effective_date: "2026-08-04", extra_repayment: "500" } ],
      rate_type: "variable", variable_rate_schedule: { "2026-05-20" => "9", "2026-09-01" => "7.5" }
    )
    pay_schedule(account)
    create_linked_loan_payment(account, 2_000, Date.new(2026, 3, 15))
    create_linked_loan_payment(account, 500, Date.new(2026, 8, 4))

    assert_replay_matches_schedule account
  end

  test "term changes under an actual day count match the changed schedule" do
    %w[actual_365 actual_actual].each do |convention|
      account = loan_with_term_changes(
        [ { effective_date: "2026-03-15", extra_repayment: "2000" }, { effective_date: "2026-07-16", balance: "5000" } ],
        day_count_convention: convention
      )
      pay_schedule(account)
      create_linked_loan_payment(account, 2_000, Date.new(2026, 3, 15))
      account.entries.create!(name: "Balance update", date: Date.new(2026, 7, 16), amount: 5_000,
                              currency: account.currency, entryable: Valuation.new(kind: "reconciliation"))

      assert_replay_matches_schedule account, convention
    end
  end

  # The extra transfer pays the instalment's premium and the instalment then
  # has none left to pay, so after the grace days the principal is where the
  # schedule has it.
  test "an extra repayment on an insured loan matches the changed schedule" do
    account = loan_with_term_changes(
      [ { effective_date: "2026-03-15", extra_repayment: "2000" } ],
      insurance_rate: 1.2, insurance_rate_type: "level_term"
    )
    insurance = account.loan.insurance
    account.loan.amortization_schedule.payments.each do |instalment|
      account.entries.create!(name: "Payment", date: instalment.date,
                              amount: -(instalment.payment.amount + insurance.premium_for(instalment.number).amount.amount),
                              currency: account.currency, entryable: Transaction.new)
    end
    create_linked_loan_payment(account, 2_000, Date.new(2026, 3, 15))

    assert_replay_matches_schedule account
  end

  test "a confirmed balance part-way through a period matches a balance update on that date" do
    account = loan_with_term_changes([ { effective_date: "2026-03-16", balance: "9000" } ])
    pay_schedule(account)
    account.entries.create!(name: "Balance update", date: Date.new(2026, 3, 16), amount: 9_000,
                            currency: account.currency, entryable: Valuation.new(kind: "reconciliation"))

    assert_replay_matches_schedule account
  end

  test "a confirmed balance on a due date matches a balance update on that date" do
    account = loan_with_term_changes([ { effective_date: "2026-03-01", balance: "10000" } ])
    pay_schedule(account)
    account.entries.create!(name: "Balance update", date: Date.new(2026, 3, 1), amount: 10_000,
                            currency: account.currency, entryable: Valuation.new(kind: "reconciliation"))

    assert_replay_matches_schedule account
  end

  private
    def principal_payments(account)
      Loan::PrincipalPayments.for(account.loan, entries: Balance::SyncCache.new(account).entries)
    end

    # 12,000 at 12% over twelve months, with the given term changes recorded.
    def loan_with_term_changes(rows, **loan_attrs)
      # Term changes cannot be dated in the future, and the replay leaves
      # future entries out.
      travel_to Date.new(2027, 6, 1)

      account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
      ], **loan_attrs)
      account.loan.update!(term_change_rows: rows)
      account.reload
    end

    def pay_schedule(account)
      account.loan.amortization_schedule.payments.each do |instalment|
        account.entries.create!(name: "Payment", date: instalment.date, amount: -instalment.payment.amount,
                                currency: account.currency, entryable: Transaction.new)
      end
    end

    def assert_replay_matches_schedule(account, message = nil)
      account.reload
      schedule = account.loan.amortization_schedule
      changes = principal_payments(account).changes
      valuations = account.entries.where(entryable_type: "Valuation").order(:date).to_a

      schedule.payments.each do |instalment|
        # The replayed balance on a date: the last balance recorded, then every
        # change after it. A payment on the day of a balance update is behind it.
        reset = valuations.select { |valuation| valuation.date <= instalment.date }.last
        replayed = reset.amount + changes
          .select { |date, _change| date > reset.date && date <= instalment.date }
          .values.sum(BigDecimal("0"), &:net)

        assert_equal instalment.ending_balance.amount, replayed,
                     [ message, "balance after payment #{instalment.number} on #{instalment.date}" ].compact.join(": ")
      end

      assert_equal schedule.total_interest.amount, changes.values.sum(BigDecimal("0"), &:interest_paid),
                   [ message, "interest paid" ].compact.join(": ")
    end
end
