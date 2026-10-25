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

  private
    def principal_payments(account)
      Loan::PrincipalPayments.for(account.loan, entries: Balance::SyncCache.new(account).entries)
    end
end
