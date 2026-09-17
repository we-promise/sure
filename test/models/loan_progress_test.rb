require "test_helper"

class LoanProgressTest < ActiveSupport::TestCase
  include EntriesTestHelper

  # 12,000 over 12 months at 0%: 1,000 of principal a month, so every figure
  # below is hand-computable and a wrong split shows up as a round number in
  # the wrong column.
  setup do
    @account = Account.create!(
      family: families(:dylan_family),
      name: "Progress Loan",
      balance: 12_000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "auto", interest_rate: 0, term_months: 12,
        rate_type: "fixed", start_date: Date.new(2026, 1, 15)
      )
    )
    @loan = @account.loan
  end

  # A month counts once it has been SERVED. Originated on 15 January, the loan
  # is not one month in on 1 February -- it is on 15 February.
  test "a month counts once it has been served in full" do
    assert_equal 0, @loan.months_elapsed(as_of: Date.new(2026, 1, 15))
    assert_equal 0, @loan.months_elapsed(as_of: Date.new(2026, 2, 14))
    assert_equal 1, @loan.months_elapsed(as_of: Date.new(2026, 2, 15))
    assert_equal 6, @loan.months_elapsed(as_of: Date.new(2026, 7, 20))
  end

  test "nothing has elapsed before the loan was drawn down" do
    assert_equal 0, @loan.months_elapsed(as_of: Date.new(2025, 12, 1))
  end

  # Elapsed is clamped to the term and remaining floors at zero: a loan running
  # past its last payment is finished, not further in than it can be.
  test "a loan past its term is finished, not overrun" do
    past = Date.new(2028, 1, 15)

    assert_equal 12, @loan.months_elapsed(as_of: past)
    assert_equal 0, @loan.remaining_months(as_of: past)
    assert @loan.finished?(as_of: past)
    assert_not @loan.finished?(as_of: Date.new(2026, 7, 15))
    assert_equal 6, @loan.remaining_months(as_of: Date.new(2026, 7, 15))
  end

  test "a loan with no term has no remaining months to report" do
    @loan.term_months = nil

    assert_nil @loan.remaining_months
    assert_nil @loan.finished?
  end

  # Read off the schedule rather than re-derived, so it cannot drift from the
  # table beside it.
  test "the remaining balance comes from the schedule" do
    assert_equal BigDecimal(11_000), @loan.remaining_balance_at(1).amount
    assert_equal BigDecimal(6_000), @loan.remaining_balance_at(6).amount
    assert_equal BigDecimal(0), @loan.remaining_balance_at(12).amount
    assert_nil @loan.remaining_balance_at(13), "there is no thirteenth payment"
    assert_nil @loan.remaining_balance_at(0)
  end

  test "one instalment splits into principal, interest and premium" do
    @loan.insurance_rate = 1.2
    @loan.insurance_rate_type = "level_term"

    breakdown = @loan.payment_breakdown(payment_number: 1)

    assert_equal 1, breakdown[:number]
    assert_equal BigDecimal(1_000), breakdown[:principal].amount
    assert_equal BigDecimal(0), breakdown[:interest].amount, "a 0% loan charges none"
    assert_equal BigDecimal(12), breakdown[:insurance].amount
    assert_equal BigDecimal(1_012), breakdown[:total].amount
    assert_in_delta 1_000.0 / 1_012, breakdown[:ratios][:principal], 0.0001
    assert_in_delta 12.0 / 1_012, breakdown[:ratios][:insurance], 0.0001
  end

  # The default is the instalment the loan is CURRENTLY on, which is the one a
  # borrower is about to pay, not the one they last paid.
  test "the breakdown defaults to the payment the loan is on" do
    travel_to Date.new(2026, 4, 20) do
      assert_equal 4, @loan.payment_breakdown[:number]
    end
  end

  test "a payment number past the end clamps to the last instalment" do
    assert_equal 12, @loan.payment_breakdown(payment_number: 99)[:number]
  end

  test "a loan with nothing to amortise has no breakdown" do
    @loan.term_months = 0

    assert_nil @loan.payment_breakdown
  end

  # Measured against the account's balance, not the schedule: the schedule says
  # what was promised, the balance says what happened.
  #
  # The fixture records what was BORROWED as a valuation at drawdown and then
  # moves the account's balance column directly.
  #
  # `account.update!(balance:)` and the current-balance anchor both rewrite the
  # account's only valuation, and with no valuation at all
  # #first_valuation_amount falls back to the current balance -- either way
  # original_balance tracks the current balance and the ratio is always zero,
  # so the fixture would be measuring nothing.
  test "paydown is measured against the balance, not the schedule" do
    assert_equal 0.0, @loan.balance_paid_ratio

    record_balance(3_000)

    assert_equal BigDecimal(12_000), reloaded_loan.original_balance.amount, "the opening balance stands"
    assert_in_delta 0.75, reloaded_loan.balance_paid_ratio, 0.0001

    segments = reloaded_loan.to_donut_segments
    assert_in_delta 0.75, segments.first[:amount], 0.0001
    assert_in_delta 0.25, segments.second[:amount], 0.0001
  end

  # A negative balance is the same debt written with the other sign, which
  # imports and manual entry both produce.
  # A fresh read through the account, because balance_paid_ratio asks the
  # ACCOUNT for its balance and a loan holding a stale association would answer
  # with the balance it was loaded with.
  def reloaded_loan
    Account.find(@account.id).loan
  end

  # A later valuation, which is what a repayment recorded against a manual loan
  # looks like. Dated after the opening one so #first_valuation -- which is
  # date-ordered -- still answers with what was borrowed.
  def record_balance(amount)
    unless @opening_recorded
      create_valuation(account: @account, amount: 12_000, date: Date.new(2026, 1, 15), currency: "USD")
      @opening_recorded = true
    end

    @account.update_column(:balance, amount)
    @account.reload
  end

  test "a debt recorded negative reads the same as one recorded positive" do
    record_balance(-3_000)

    assert_in_delta 0.75, reloaded_loan.balance_paid_ratio, 0.0001
  end

  test "a cleared loan is fully repaid" do
    record_balance(0)

    assert_equal 1.0, reloaded_loan.balance_paid_ratio
  end

  # A balance above what was borrowed -- arrears, capitalised interest, a
  # redraw -- is no progress rather than negative progress. The ring cannot
  # draw a negative arc and the figure would read as a gain.
  test "owing more than was borrowed is not negative progress" do
    record_balance(15_000)

    assert_equal 0.0, reloaded_loan.balance_paid_ratio
  end
end
