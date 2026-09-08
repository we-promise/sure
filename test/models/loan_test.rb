require "test_helper"

class LoanTest < ActiveSupport::TestCase
  include AccrualLoanHelper

  test "rejects invalid subtype" do
    loan = Loan.new(subtype: "invalid")

    assert_not loan.valid?
    assert_includes loan.errors[:subtype], "is not included in the list"
  end

  test "calculates correct monthly payment for fixed rate loan" do
    loan_account = Account.create! \
      family: families(:dylan_family),
      name: "Mortgage Loan",
      balance: 500000,
      currency: "USD",
      accountable: Loan.create!(
        subtype: "mortgage",
        interest_rate: 3.5,
        term_months: 360,
        rate_type: "fixed"
      )

    assert_equal 2245, loan_account.loan.monthly_payment.amount
  end

  test "rejects an out of range interest accrual day" do
    assert_not Loan.new(interest_accrual_day: 0).valid?
    assert_not Loan.new(interest_accrual_day: 32).valid?
    assert Loan.new(interest_accrual_day: nil).valid?
    assert Loan.new(interest_accrual_day: 15).valid?
  end

  test "only accrues interest when opted in, rated, dated and unlinked" do
    assert accrual_loan.accrues_interest?

    assert_not accrual_loan(accrue_interest: false).accrues_interest?
    assert_not accrual_loan(interest_rate: 0).accrues_interest?

    # A saved record can't reach this state — the validation forbids it — but the
    # predicate must not assume that, since the accrual engine reads it directly.
    undated = accrual_loan
    undated.interest_accrual_start_date = nil
    assert_not undated.accrues_interest?

    # Unlike an amortization schedule, accrual works off the balance outstanding
    # on the day, so it is valid for non-fixed rates too.
    assert accrual_loan(rate_type: "variable").accrues_interest?

    # A linked account is anchored to the principal its provider reports, so a
    # replay from origination has no reliable starting point.
    linked = accrual_loan
    Account.any_instance.stubs(:unlinked?).returns(false)
    assert_not linked.accrues_interest?
  end

  test "requires a rate and start date before accrual can be enabled" do
    loan = Loan.new(accrue_interest: true)

    assert_not loan.valid?
    assert_includes loan.errors[:interest_rate], "can't be blank"
    assert_includes loan.errors[:interest_accrual_start_date], "can't be blank"
  end

  # Nothing else syncs on this path — AccountableResource#update only syncs when
  # the account balance changed — so without this the user flips the toggle and
  # sees nothing happen until the next daily SyncAllJob.
  test "resyncs the account when an accrual input changes" do
    loan = accrual_loan

    Account.any_instance.expects(:sync_later).once
    loan.update!(interest_rate: 7)
  end

  test "does not resync for changes that cannot affect accrual" do
    loan = accrual_loan

    Account.any_instance.expects(:sync_later).never
    loan.update!(subtype: "auto")
  end

  test "converts the annual rate to a monthly rate" do
    assert_nil Loan.new(interest_rate: nil).monthly_interest_rate
    assert_equal 0.005.to_d, Loan.new(interest_rate: 6).monthly_interest_rate
  end

  test "resolves the interest rate effective on a given date" do
    loan = accrual_loan # base rate 6
    loan.rate_changes.create!(effective_date: Date.new(2026, 6, 1), rate: 9)
    loan.rate_changes.create!(effective_date: Date.new(2027, 1, 1), rate: 12)

    assert_equal 6, loan.interest_rate_on(Date.new(2026, 5, 31)) # before any change -> base
    assert_equal 9, loan.interest_rate_on(Date.new(2026, 6, 1))  # on the effective date
    assert_equal 9, loan.interest_rate_on(Date.new(2026, 12, 31))
    assert_equal 12, loan.interest_rate_on(Date.new(2027, 6, 1))
  end

  # Two new rate changes sharing a date in one save both pass Loan::RateChange's
  # own uniqueness check (nothing persisted to conflict with) and would hit the
  # DB unique index as an unrescued RecordNotUnique. The loan-level check catches
  # it as a validation error instead.
  test "rejects two rate changes with the same effective date in one save" do
    loan = accrual_loan
    loan.rate_changes.build(effective_date: Date.new(2026, 6, 1), rate: 9)
    loan.rate_changes.build(effective_date: Date.new(2026, 6, 1), rate: 10)

    assert_not loan.valid?
    assert_includes loan.errors[:base], "Rate change effective dates must be unique"
  end

  # A rate change moves the derived balance but is a child row, so it never
  # touches the loan's own saved_changes — Loan::RateChange must trigger the sync
  # itself (via resync_loan_account, wired to both save and destroy commits).
  test "resyncs the account when a rate change is removed" do
    loan = accrual_loan
    rate_change = loan.rate_changes.create!(effective_date: Date.new(2026, 6, 1), rate: 9)

    Account.any_instance.expects(:sync_later).once
    rate_change.destroy!
  end

  # The save-commit callback doesn't fire for freshly created/updated records in
  # transactional tests, so assert the callback body directly to cover the
  # add/edit resync path (the removed test above covers the wiring end-to-end).
  test "a saved rate change asks its loan to resync" do
    loan = accrual_loan
    rate_change = loan.rate_changes.create!(effective_date: Date.new(2026, 6, 1), rate: 9)

    rate_change.loan.expects(:resync_for_accrual!).once
    rate_change.send(:resync_loan_account)
  end

  test "the system-generated source list covers the accrual source" do
    assert_includes Entry::SYSTEM_GENERATED_SOURCES, Loan::InterestAccrual::SOURCE
  end
end
