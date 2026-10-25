require "test_helper"

class Loan::PaidBreakdownTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  OPENING_DATE = Date.new(2026, 1, 1)
  PAYMENT_DATE = Date.new(2026, 2, 1)

  test "sums the ledger's principal and interest" do
    account = create_loan_account(initial_balance: 12_000, term_months: 12, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -1_066.19 }
    ])
    enable_preview_features_for_family!(account.family)

    paid = account.loan.paid_breakdown(as_of: PAYMENT_DATE)

    assert_equal Money.new(946.19, "USD"), paid.principal
    assert_equal Money.new(120, "USD"), paid.interest
    assert_equal Money.new(1_066.19, "USD"), paid.total
    assert_in_delta 1.0, paid.ratios.values.sum, 0.0001
  end

  test "a linked principal-only transfer counts the interest paid separately" do
    account = create_loan_account(initial_balance: 12_000, term_months: 12,
                                  principal_only_transfers: true, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    enable_preview_features_for_family!(account.family)
    instalment = account.loan.amortization_schedule.payments.first

    create_linked_loan_payment(account, instalment.principal.amount, instalment.date)
    account.reload

    paid = account.loan.paid_breakdown(as_of: instalment.date)

    assert_equal instalment.principal, paid.principal
    assert_equal instalment.interest, paid.interest
    assert_equal instalment.payment, paid.total
  end

  test "stops at the requested date" do
    account = create_loan_account(initial_balance: 12_000, term_months: 12, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -1_066.19 },
      { type: "transaction", date: Date.new(2026, 3, 1), amount: -1_066.19 }
    ])
    enable_preview_features_for_family!(account.family)

    paid = account.loan.paid_breakdown(as_of: PAYMENT_DATE)

    assert_equal Money.new(946.19, "USD"), paid.principal
    assert_equal Money.new(120, "USD"), paid.interest
  end

  test "falls back to the current anchor when there is no opening anchor" do
    account = create_loan_account(initial_balance: 12_000, term_months: 12, entries: [
      { type: "current_anchor", date: Date.current, balance: 11_053.81 }
    ])
    enable_preview_features_for_family!(account.family)
    scheduled_interest = account.loan.amortization_schedule.payments
      .select { |payment| payment.date <= Date.current }
      .sum(BigDecimal("0")) { |payment| payment.interest.amount }

    paid = account.loan.paid_breakdown(as_of: Date.current)

    assert_equal Money.new(946.19, "USD"), paid.principal
    assert_equal Money.new(scheduled_interest, "USD"), paid.interest
  end

  test "a new loan reports zero paid" do
    account = create_loan_account(initial_balance: 12_000, term_months: 12, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    enable_preview_features_for_family!(account.family)

    paid = account.loan.paid_breakdown(as_of: OPENING_DATE)

    assert_equal Money.new(0, "USD"), paid.principal
    assert_equal Money.new(0, "USD"), paid.interest
    assert_equal Money.new(0, "USD"), paid.total
  end

  test "has no paid breakdown when preview is off" do
    account = create_loan_account(initial_balance: 12_000, term_months: 12, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -1_066.19 }
    ])

    assert_nil account.loan.paid_breakdown(as_of: PAYMENT_DATE)
  end

  test "has no paid breakdown without terms" do
    account = create_account_with_ledger(
      account: { type: Loan, currency: "USD" },
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
      ]
    )
    enable_preview_features_for_family!(account.family)

    assert_nil account.loan.paid_breakdown(as_of: PAYMENT_DATE)
  end

  test "the paid breakdown does not write missing-rate diagnostics" do
    account = create_loan_account(initial_balance: 12_000, term_months: 12, entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 12_000 }
    ])
    enable_preview_features_for_family!(account.family)
    account.entries.create!(name: "EUR transaction", date: PAYMENT_DATE, amount: 100,
                            currency: "EUR", entryable: Transaction.new)
    account.reload

    assert_no_difference "DebugLogEntry.count" do
      account.loan.paid_breakdown(as_of: PAYMENT_DATE)
    end
  end
end
