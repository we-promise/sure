require "test_helper"

class Loan::PaymentSplitterTest < ActiveSupport::TestCase
  setup do
    loan = Loan.new(
      annuity_enabled: true,
      started_on: Date.new(2024, 1, 1),
      payment_cadence: "monthly",
      initial_balance: 300000,
      term_months: 360,
      rate_type: "fixed"
    )
    loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 6.0)
    @account = Account.create!(
      family: families(:dylan_family),
      name: "Annuity Mortgage",
      balance: 300000,
      currency: "USD",
      accountable: loan
    )
  end

  test "splits scheduled payment into interest and principal" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 2, 1),
      amount: 1798.65
    )

    assert split.matched?
    assert_equal 1, split.period_number
    assert_in_delta 1500, split.interest, 0.01
    assert_in_delta 298.65, split.principal, 0.01
    assert_in_delta 0, split.extra_principal, 0.01
    assert_in_delta 0, split.variance, 0.01
  end

  test "treats payment above scheduled amount as extra principal" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 2, 1),
      amount: 2000
    )

    assert split.matched?
    assert_in_delta 1500, split.interest, 0.01
    assert_in_delta 298.65, split.principal, 0.01
    assert_in_delta 201.35, split.extra_principal, 0.01
    assert_in_delta 0, split.variance, 0.01
  end

  test "records underpayment variance instead of forcing scheduled balance" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 2, 1),
      amount: 1000
    )

    assert split.matched?
    assert_in_delta 1000, split.interest, 0.01
    assert_in_delta 0, split.principal, 0.01
    assert_in_delta 0, split.extra_principal, 0.01
    assert_in_delta 798.65, split.variance, 0.01
  end

  test "returns unmatched split when no schedule row is close enough" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 4, 20),
      amount: 1798.65,
      paid_period_numbers: [ 1, 2, 3 ]
    )

    assert_not split.matched?
    assert_nil split.period_number
    assert_in_delta 0, split.interest, 0.01
    assert_in_delta 0, split.principal, 0.01
    assert_in_delta 1798.65, split.variance, 0.01
  end

  test "skips schedule rows already recorded on loan transactions" do
    @account.entries.create!(
      amount: -298.65,
      currency: "USD",
      date: Date.new(2024, 2, 1),
      name: "Payment from Checking",
      entryable: Transaction.new(
        kind: "funds_movement",
        extra: {
          "loan_payment_split" => {
            "period_number" => 1
          }
        }
      )
    )

    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 3, 1),
      amount: 1798.65
    )

    assert split.matched?
    assert_equal 2, split.period_number
  end
end
