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

  test "a change that records nothing is invalid" do
    change = build
    assert_not change.valid?
    assert_includes change.errors.full_messages, I18n.t("activerecord.errors.models.loan/term_change.records_nothing")
  end

  test "a fixed-until date alone makes a valid change that leaves the schedule alone" do
    change = build(term_end_date: Date.new(2031, 3, 15))

    assert change.valid?
    assert_not change.changes_schedule?
    assert build(payment: 0, term_end_date: Date.new(2031, 3, 15)).changes_schedule?
  end

  test "the fixed period ends after it starts" do
    assert build(payment: 850, term_end_date: Date.new(2026, 3, 16)).valid?

    [ Date.new(2026, 3, 15), Date.new(2026, 3, 14) ].each do |term_end_date|
      change = build(payment: 850, term_end_date: term_end_date)
      assert_not change.valid?, term_end_date.to_s
      assert_includes change.errors.full_messages, I18n.t("activerecord.errors.models.loan/term_change.term_ends_before_it_starts")
    end
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

  test "a payment and a fixed-until date can be dated ahead, a repayment or a balance cannot" do
    tomorrow = Date.current + 1
    assert build(effective_date: tomorrow, payment: 850).valid?
    assert build(effective_date: tomorrow, payment: 850, term_end_date: tomorrow + 5.years).valid?
    assert build(effective_date: tomorrow, term_end_date: tomorrow + 5.years).valid?
    assert build(effective_date: Date.current, extra_repayment: 2_000).valid?
    assert build(effective_date: Date.current, balance: 9_000).valid?

    [ { extra_repayment: 2_000 }, { balance: 9_000 }, { balance: 0, payment: 850 } ].each do |amounts|
      change = build(effective_date: tomorrow, **amounts)
      assert_not change.valid?, amounts.inspect
      assert_includes change.errors.full_messages, I18n.t("activerecord.errors.models.loan/term_change.balance_change_in_the_future")
    end
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
    assert_raises(ActiveRecord::StatementInvalid) { build(payment: 850, term_end_date: Date.new(2026, 3, 15)).save!(validate: false) }
  end

  test "the database stores a change that records only a fixed-until date" do
    build(term_end_date: Date.new(2031, 3, 15)).save!

    assert_equal Date.new(2031, 3, 15), @loan.term_changes.reload.first.term_end_date
  end

  test "deleting the loan deletes its term changes" do
    build(payment: 850).save!

    assert_difference "Loan::TermChange.count", -1 do
      @loan.account.destroy!
    end
  end

  private
    def build(effective_date: Date.new(2026, 3, 15), **attributes)
      Loan::TermChange.new(loan: @loan, effective_date: effective_date, **attributes)
    end
end
