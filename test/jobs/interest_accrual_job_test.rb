require "test_helper"

class InterestAccrualJobTest < ActiveJob::TestCase
  setup do
    @account = accounts(:savings_with_interest)
    @depository = depositories(:savings_with_interest)
  end

  test "creates accrual for eligible account" do
    assert_difference "InterestAccrual.count", 1 do
      InterestAccrualJob.perform_now
    end

    accrual = @depository.interest_accruals.find_by(date: Date.current)
    assert_not_nil accrual
    assert_equal @depository.id, accrual.depository_id
    assert accrual.amount > 0
    assert_not accrual.paid_out
  end

  test "idempotent — no duplicate on re-run" do
    InterestAccrualJob.perform_now

    assert_no_difference "InterestAccrual.count" do
      InterestAccrualJob.perform_now
    end
  end

  test "skips accounts with interest disabled" do
    @depository.update!(interest_enabled: false)

    assert_no_difference "InterestAccrual.count" do
      InterestAccrualJob.perform_now
    end
  end

  test "skips accounts with zero balance" do
    @account.update!(balance: 0)

    assert_no_difference "InterestAccrual.count" do
      InterestAccrualJob.perform_now
    end
  end
end
