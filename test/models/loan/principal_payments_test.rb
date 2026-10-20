require "test_helper"

class Loan::PrincipalPaymentsTest < ActiveSupport::TestCase
  include LedgerTestingHelper

  OPENING_DATE = Date.new(2026, 1, 1)
  PAYMENT_DATE = Date.new(2026, 1, 31)

  test "splits payments for every loan subtype" do
    Loan::SUBTYPES.each_key do |subtype|
      account = create_loan(subtype: subtype, entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
        { type: "transaction", date: PAYMENT_DATE, amount: -2_000 }
      ])

      change = principal_payments(account).change_for(PAYMENT_DATE)

      assert_equal BigDecimal("1802.74"), change.principal_paid, "#{subtype} should split principal from interest"
      assert_equal BigDecimal("0"), change.principal_added
      assert_equal BigDecimal("197.26"), change.interest_paid
      assert_equal BigDecimal("0"), change.linked_paid
      assert_equal BigDecimal("-1802.74"), change.net
    end
  end

  test "a payment below accrued interest does not reduce principal" do
    account = create_loan(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -100 }
    ])

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("0"), change.principal_paid
    assert_equal BigDecimal("100"), change.interest_paid, "only the part of the accrued interest that was paid"
    assert_equal BigDecimal("0"), change.net
  end

  test "a payment above interest reduces principal by the excess" do
    account = create_loan(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -5_000 }
    ])

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("4802.74"), change.principal_paid
    assert_equal BigDecimal("-4802.74"), change.net
  end

  test "later payments accrue interest on the reduced principal" do
    account = create_loan(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -10_000 },
      { type: "transaction", date: Date.new(2026, 3, 2), amount: -2_000 }
    ])

    payments = principal_payments(account)

    assert_equal BigDecimal("9802.74"), payments.change_for(PAYMENT_DATE).principal_paid
    assert_equal BigDecimal("1899.42"), payments.change_for(Date.new(2026, 3, 2)).principal_paid
  end

  test "drawdowns increase principal for later interest" do
    account = create_loan(
      subtype: "line_of_credit",
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
        { type: "transaction", date: PAYMENT_DATE, amount: 5_000 },
        { type: "transaction", date: Date.new(2026, 3, 2), amount: -2_000 }
      ]
    )

    payments = principal_payments(account)

    assert_equal BigDecimal("5000"), payments.change_for(PAYMENT_DATE).principal_added
    assert_equal BigDecimal("0"), payments.change_for(PAYMENT_DATE).principal_paid
    assert_equal BigDecimal("1753.42"), payments.change_for(Date.new(2026, 3, 2)).principal_paid
  end

  test "interest follows recorded rate changes" do
    account = create_loan(
      rate_type: "variable",
      variable_rate_schedule: { "2026-01-16" => "24.0" },
      entries: [
        { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
        { type: "transaction", date: PAYMENT_DATE, amount: -2_000 }
      ]
    )

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("1704.11"), change.principal_paid
    assert_equal BigDecimal("295.89"), change.interest_paid
  end

  test "reconciliation resets the principal used for later interest" do
    account = create_loan(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 },
      { type: "transaction", date: PAYMENT_DATE, amount: -2_000 },
      { type: "reconciliation", date: Date.new(2026, 2, 15), balance: 10_000 },
      { type: "transaction", date: Date.new(2026, 3, 17), amount: -1_000 }
    ])

    payments = principal_payments(account)

    assert_equal BigDecimal("1802.74"), payments.change_for(PAYMENT_DATE).principal_paid
    assert_equal BigDecimal("0"), payments.change_for(Date.new(2026, 2, 15)).net
    assert_equal BigDecimal("901.37"), payments.change_for(Date.new(2026, 3, 17)).principal_paid
  end

  test "linked transfers are already principal-only" do
    account = create_loan(entries: [
      { type: "opening_anchor", date: OPENING_DATE, balance: 20_000 }
    ])
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
      date: PAYMENT_DATE,
      amount: 2_000
    ).create
    account.reload

    change = principal_payments(account).change_for(PAYMENT_DATE)

    assert_equal BigDecimal("2000"), change.principal_paid, "a linked loan transfer must not have interest deducted twice"
    assert_equal BigDecimal("0"), change.principal_added
    assert_equal BigDecimal("0"), change.interest_paid, "linked transfers carry principal only"
    assert_equal BigDecimal("2000"), change.linked_paid
  end

  test "a loan without an opening anchor is left alone" do
    account = create_loan(entries: [
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
    def create_loan(subtype: "mortgage", entries:, **loan_attrs)
      account = create_account_with_ledger(
        account: { type: Loan, currency: "USD" },
        entries: entries
      )
      account.loan.update!(
        {
          subtype: subtype,
          interest_rate: 12,
          term_months: 360,
          rate_type: "fixed",
          start_date: OPENING_DATE,
          initial_balance: 20_000
        }.merge(loan_attrs)
      )
      account.reload
    end

    def principal_payments(account)
      Loan::PrincipalPayments.for(account.loan, entries: Balance::SyncCache.new(account).entries)
    end
end
