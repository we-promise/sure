require "test_helper"

class Assistant::Function::GetBalanceSheetTest < ActiveSupport::TestCase
  include BalanceTestHelper

  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::GetBalanceSheet.new(@user)
  end

  test "has correct name" do
    assert_equal "get_balance_sheet", @fn.name
  end

  test "is not in strict mode" do
    refute @fn.to_definition[:strict]
  end

  test "default call preserves the established shape" do
    result = @fn.call

    assert result[:net_worth][:current].present?
    assert result[:assets].key?(:monthly_history)
    assert result[:liabilities].key?(:monthly_history)
    assert result[:insights][:debt_to_asset_ratio].present?
  end

  test "named period bounds the history series" do
    result = @fn.call("period" => "last_30_days")

    series = result[:net_worth][:monthly_history]

    assert series[:start_date] >= 31.days.ago.to_date
  end

  test "invalid custom dates return an invalid_date error" do
    result = @fn.call("start_date" => "not-a-date", "end_date" => "2024-01-01")

    assert_equal "invalid_date", result[:error]
  end

  test "a reversed custom range returns the structured error" do
    result = @fn.call("start_date" => "2025-06-01", "end_date" => "2025-01-01")

    assert_equal "invalid_date", result[:error]
  end

  test "history scales an account's contribution to the viewer's ownership share" do
    account = accounts(:depository)
    account.balances.destroy_all
    create_balance(account: account, date: Date.current, balance: 1000)

    history = lambda do
      Assistant::Function::GetBalanceSheet.new(@user.reload)
        .call("period" => "last_30_days", "interval" => "1 day")[:net_worth][:monthly_history][:values].last
    end

    full = history.call
    account.update!(ownership_percentage: 50)
    scaled = history.call

    # Only this account's contribution (1000) is halved; everything else is unchanged.
    assert_in_delta 500, full - scaled, 0.01
  end

  test "too many points returns an error instead of a giant series" do
    result = @fn.call("period" => "last_10_years", "interval" => "1 day")

    assert_equal "too_many_points", result[:error]
  end
end
