require "test_helper"

class BalanceSheet::AccountActiveUntilDatesTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @account = accounts(:depository)
    @account.balances.destroy_all
  end

  test "zero-balance accounts stop at their last balance entry" do
    create_balance(account: @account, date: 10.days.ago.to_date, balance: 1000)
    create_balance(account: @account, date: 5.days.ago.to_date, balance: 0)

    assert_equal({ @account.id => 5.days.ago.to_date }, active_until_dates)
  end

  test "accounts still holding a balance stay in the chart" do
    create_balance(account: @account, date: 5.days.ago.to_date, balance: 0)
    create_balance(account: @account, date: 1.day.ago.to_date, balance: 500)

    assert_equal({}, active_until_dates)
  end

  test "a disabled account keeps the earlier cutoff" do
    @account.update_columns(status: "disabled", disabled_at: 3.days.ago)
    create_balance(account: @account, date: 1.day.ago.to_date, balance: 0)

    assert_equal({ @account.id => 4.days.ago.to_date }, active_until_dates)
  end

  test "a zero balance can stop a disabled account before it was disabled" do
    @account.update_columns(status: "disabled", disabled_at: 3.days.ago)
    create_balance(account: @account, date: 10.days.ago.to_date, balance: 0)

    assert_equal({ @account.id => 10.days.ago.to_date }, active_until_dates)
  end

  private
    def active_until_dates
      BalanceSheet::AccountActiveUntilDates.new([ @account.reload ]).to_h
    end
end
