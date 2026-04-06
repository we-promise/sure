require "test_helper"

class InterestPayoutJobTest < ActiveJob::TestCase
  setup do
    @account = accounts(:savings_with_interest)
    @depository = depositories(:savings_with_interest)

    # Create accruals for the previous month
    prev_month = Date.current.prev_month
    @depository.interest_accruals.destroy_all

    3.times do |i|
      InterestAccrual.create!(
        depository: @depository,
        date: prev_month.beginning_of_month + i.days,
        balance_used: 10000,
        daily_rate: 0.000075342466,
        amount: 0.7534,
        paid_out: false
      )
    end
  end

  test "creates interest payment transaction" do
    assert_difference "@account.entries.count", 1 do
      InterestPayoutJob.perform_now
    end

    entry = @account.entries.order(created_at: :desc).first
    assert entry.amount.negative?
    assert_equal "Transaction", entry.entryable_type
    assert_match(/Interest Payment/, entry.name)
  end

  test "categorizes transaction as Interest" do
    InterestPayoutJob.perform_now

    entry = @account.entries.order(created_at: :desc).first
    assert_equal "Interest", entry.transaction.category.name
  end

  test "tags transaction as auto-generated" do
    InterestPayoutJob.perform_now

    entry = @account.entries.order(created_at: :desc).first
    assert_includes entry.transaction.tags.map(&:name), "auto-generated"
  end

  test "marks accruals as paid out" do
    InterestPayoutJob.perform_now

    prev_month = Date.current.prev_month
    unpaid = @depository.interest_accruals.unpaid.for_month(prev_month.year, prev_month.month)
    assert_equal 0, unpaid.count
  end

  test "idempotent — no duplicate payout on re-run" do
    InterestPayoutJob.perform_now

    assert_no_difference "@account.entries.count" do
      InterestPayoutJob.perform_now
    end
  end

  test "triggers account sync" do
    Account.any_instance.expects(:sync_later).once
    InterestPayoutJob.perform_now
  end

  test "skips when no unpaid accruals" do
    @depository.interest_accruals.update_all(paid_out: true)

    assert_no_difference "@account.entries.count" do
      InterestPayoutJob.perform_now
    end
  end
end
