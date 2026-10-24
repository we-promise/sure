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

  test "a ledger interest line replaces the engine's charge" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: 100 },
      { type: "transaction", date: PAYMENT_DATE, amount: -1_066.19 }
    ])

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("100"), change.interest_paid, "the statement's interest, not the schedule's 120"
    assert_equal BigDecimal("966.19"), change.principal_paid
  end

  test "a late interest line replaces the carried charge" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    instalment = account.loan.amortization_schedule.payments.first
    late_date = instalment.date + 4.days

    account.entries.create!(name: "Interest", date: late_date, amount: 100,
                            currency: account.currency, entryable: Transaction.new)
    account.entries.create!(name: "Payment", date: late_date,
                            amount: -instalment.payment.amount,
                            currency: account.currency, entryable: Transaction.new)
    account.reload

    change = principal_payments(account).change_for(late_date)

    assert_equal BigDecimal("100"), change.interest_paid, "the statement's charge, not the carried 120 plus 100"
    assert_equal BigDecimal("966.19"), change.principal_paid
  end

  test "a late principal-only transfer pays the period it missed" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
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

  test "a payment above the remaining principal is capped" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -20_000 }
    ])

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("12_000"), change.principal_paid
    assert_equal BigDecimal("120"), change.interest_paid
    assert_equal BigDecimal("-12_000"), change.net
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

  test "a linked transfer equal to the scheduled principal is principal-only" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    instalment = account.loan.amortization_schedule.payments.first

    create_linked_loan_payment(account, instalment.principal.amount, instalment.date)
    account.reload

    change = principal_payments(account).change_for(instalment.date)

    assert_equal BigDecimal("946.19"), change.principal_paid
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

  test "an interest line already in the ledger is not counted twice" do
    account = create_loan_account(term_months: 12, initial_balance: 12_000, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: 120 },
      { type: "transaction", date: PAYMENT_DATE, amount: -1_066.19 }
    ])

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("946.19"), change.principal_paid
    assert_equal BigDecimal("120"), change.interest_paid
    assert_equal BigDecimal("11_053.81"), (BigDecimal("12_000") + change.net)
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
    assert_equal BigDecimal("1810"), payments.change_for(Date.new(2026, 3, 2)).principal_paid,
                 "interest on the reconciliation balance for the shortened period"
    assert_equal BigDecimal("190"), payments.change_for(Date.new(2026, 3, 2)).interest_paid
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
