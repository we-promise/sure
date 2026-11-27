require "test_helper"

class Loan::TermChangeTest < ActiveSupport::TestCase
  setup do
    @loan = loans(:one)
    travel_to Date.new(2026, 6, 15)
  end

  test "an extra repayment, a confirmed balance or a payment each make a valid change" do
    assert build(extra_repayment: 2_000).valid?
    assert build(balance: 9_000).valid?
    assert build(payment: 850).valid?
    assert build(extra_repayment: 2_000, payment: 850).valid?
    assert build(balance: 9_000, payment: 850).valid?
  end

  test "a change needs an effective date" do
    assert_not build(effective_date: nil, payment: 850).valid?
  end

  test "a change that changes nothing is invalid" do
    change = build
    assert_not change.valid?
    assert_includes change.errors.full_messages, I18n.t("activerecord.errors.models.loan/term_change.no_amount")
  end

  test "an extra repayment and a confirmed balance cannot share a change" do
    change = build(extra_repayment: 2_000, balance: 9_000)
    assert_not change.valid?
    assert_includes change.errors.full_messages, I18n.t("activerecord.errors.models.loan/term_change.two_balance_changes")
  end

  test "an extra repayment is positive" do
    assert_not build(extra_repayment: 0).valid?
    assert_not build(extra_repayment: -1).valid?
  end

  test "a confirmed balance and a payment can be zero but not negative" do
    assert build(balance: 0).valid?
    assert build(payment: 0).valid?
    assert_not build(balance: -1).valid?
    assert_not build(payment: -1).valid?
  end

  test "an amount the column cannot hold is invalid instead of raising on save" do
    assert_not build(extra_repayment: Loan::TermChange::AMOUNT_LIMIT).valid?
    assert_not build(balance: Loan::TermChange::AMOUNT_LIMIT).valid?
    assert_not build(payment: Loan::TermChange::AMOUNT_LIMIT).valid?
  end

  test "a change cannot be dated in the future" do
    assert build(effective_date: Date.current, payment: 850).valid?

    change = build(effective_date: Date.current + 1, payment: 850)
    assert_not change.valid?
    assert_includes change.errors.full_messages, I18n.t("activerecord.errors.models.loan/term_change.in_the_future")
  end

  test "the database refuses two changes on one date for a loan" do
    build(payment: 850).save!

    assert_raises(ActiveRecord::RecordNotUnique) { build(payment: 900).save! }
  end

  test "the database refuses what the validations refuse" do
    assert_raises(ActiveRecord::StatementInvalid) { build.save!(validate: false) }
    assert_raises(ActiveRecord::StatementInvalid) { build(extra_repayment: 1, balance: 1).save!(validate: false) }
    assert_raises(ActiveRecord::StatementInvalid) { build(extra_repayment: 0).save!(validate: false) }
    assert_raises(ActiveRecord::StatementInvalid) { build(balance: -1).save!(validate: false) }
    assert_raises(ActiveRecord::StatementInvalid) { build(payment: -1).save!(validate: false) }
  end

  test "deleting the loan deletes its term changes" do
    build(payment: 850).save!

    assert_difference "Loan::TermChange.count", -1 do
      @loan.account.destroy!
    end
  end

  private
    def build(effective_date: Date.new(2026, 3, 15), **amounts)
      Loan::TermChange.new(loan: @loan, effective_date: effective_date, **amounts)
    end
end
