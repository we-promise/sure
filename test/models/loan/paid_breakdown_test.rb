require "test_helper"

class Loan::PaidBreakdownTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  OPENING_DATE = Date.new(2026, 1, 15)
  PAYMENT_DATE = Date.new(2026, 2, 15)

  test "splits an unlinked payment using the ledger's actual interest" do
    account = create_loan(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -1_066.19 }
    ])

    paid = account.loan.paid_breakdown(as_of: PAYMENT_DATE)

    assert_equal Money.new(943.89, "USD"), paid.principal
    assert_equal Money.new(122.30, "USD"), paid.interest
    assert_equal Money.new(1_066.19, "USD"), paid.total
    assert_in_delta 1.0, paid.ratios.values.sum, 0.0001
  end

  test "adds scheduled interest for a linked principal-only instalment" do
    account = create_loan(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    instalment = account.loan.amortization_schedule.payments.first

    create_linked_payment(account, instalment.principal.amount, instalment.date)
    account.reload

    paid = account.loan.paid_breakdown(as_of: instalment.date)

    assert_equal instalment.principal, paid.principal
    assert_equal instalment.interest, paid.interest, "the interest was paid as a separate expense"
    assert_equal instalment.payment, paid.total
  end

  test "a linked prepayment does not add a second instalment's interest" do
    account = create_loan(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    instalment = account.loan.amortization_schedule.payments.first

    create_linked_payment(account, instalment.principal.amount, instalment.date)
    create_linked_payment(account, 2_000, instalment.date + 5)
    account.reload

    paid = account.loan.paid_breakdown(as_of: instalment.date + 5)

    assert_equal instalment.principal + Money.new(2_000, "USD"), paid.principal
    assert_equal instalment.interest, paid.interest
  end

  test "an unlinked instalment and a linked transfer in one month do not double-count interest" do
    account = create_loan(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -1_066.19 }
    ])
    instalment = account.loan.amortization_schedule.payments.first

    create_linked_payment(account, instalment.principal.amount, PAYMENT_DATE + 5)
    account.reload

    paid = account.loan.paid_breakdown(as_of: PAYMENT_DATE + 5)

    assert_equal BigDecimal("122.30"), paid.interest.amount
  end

  test "a loan without an opening anchor uses the balance and the schedule" do
    as_of = Date.new(2026, 4, 20)
    account = create_loan(entries: [
      { type: "current_anchor", date: OPENING_DATE, balance: 9_000 }
    ])
    account.update_column(:balance, 9_000)

    paid = account.loan.paid_breakdown(as_of: as_of)
    scheduled = account.loan.amortization_schedule.payments.select { |payment| payment.date <= as_of }
    expected_interest = scheduled.sum(BigDecimal("0")) { |payment| payment.interest.amount }

    assert_equal Money.new(3_000, "USD"), paid.principal
    assert_equal Money.new(expected_interest, "USD"), paid.interest
  end

  test "an opening anchor with no payments does not invent paid instalments" do
    account = create_loan(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])

    paid = account.loan.paid_breakdown(as_of: Date.new(2026, 4, 20))

    assert_equal Money.new(0, "USD"), paid.principal
    assert_equal Money.new(0, "USD"), paid.interest
    assert_equal Money.new(0, "USD"), paid.total
  end

  test "a loan without terms has no paid breakdown" do
    account = create_account_with_ledger(
      account: { type: Loan, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
      ]
    )

    assert_nil account.loan.paid_breakdown(as_of: Date.new(2026, 4, 20))
  end

  private
    def create_loan(entries:, **loan_attrs)
      account = create_account_with_ledger(
        account: { type: Loan, currency: "USD" },
        entries: entries
      )
      account.loan.update!(
        {
          subtype: "auto",
          interest_rate: 12,
          term_months: 12,
          rate_type: "fixed",
          start_date: OPENING_DATE,
          initial_balance: 12_000
        }.merge(loan_attrs)
      )
      account.reload
    end

    def create_linked_payment(account, amount, date)
      source = account.family.accounts.create!(
        name: "Checking",
        balance: 10_000,
        currency: "USD",
        accountable: Depository.new
      )

      Transfer::Creator.new(
        family: account.family,
        source_account_id: source.id,
        destination_account_id: account.id,
        date: date,
        amount: amount
      ).create
    end
end
