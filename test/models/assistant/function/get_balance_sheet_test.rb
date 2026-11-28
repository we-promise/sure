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

  test "too many points returns an error instead of a giant series" do
    result = @fn.call("period" => "last_10_years", "interval" => "1 day")

    assert_equal "too_many_points", result[:error]
  end

  test "history leaves out a shared account the member excludes from finances" do
    account_shares(:depository_shared_with_member).update!(include_in_finances: false)

    ids = captured_history_account_ids(users(:family_member))

    assert_equal [ accounts(:credit_card).id ], ids[:net_worth]
    assert_empty ids[:assets]
    assert_equal [ accounts(:credit_card).id ], ids[:liabilities]
  end

  test "history keeps a shared account the member leaves in their finances" do
    ids = captured_history_account_ids(users(:family_member))

    assert_equal [ accounts(:credit_card).id, accounts(:depository).id ].sort, ids[:net_worth]
    assert_equal [ accounts(:depository).id ], ids[:assets]
    assert_equal [ accounts(:credit_card).id ], ids[:liabilities]
  end

  test "history leaves out an account excluded from reports" do
    accounts(:credit_card).update!(exclude_from_reports: true)

    ids = captured_history_account_ids(users(:family_member))

    assert_equal [ accounts(:depository).id ], ids[:net_worth]
    assert_equal [ accounts(:depository).id ], ids[:assets]
    assert_empty ids[:liabilities]
  end

  test "current also leaves out an account excluded from reports" do
    accounts(:credit_card).update!(exclude_from_reports: true)

    result = Assistant::Function::GetBalanceSheet.new(users(:family_member)).call("period" => "last_30_days")

    assert_equal "$0.00", result[:liabilities][:current]
  end

  test "history keeps a disabled account through the day before it was disabled" do
    user = users(:empty)
    family = user.family

    active_account = family.accounts.create!(
      owner: user, name: "Checking", balance: 0, currency: "USD", accountable: Depository.new
    )
    disabled_account = family.accounts.create!(
      owner: user, name: "Old checking", balance: 0, currency: "USD", accountable: Depository.new
    )
    disabled_account.disable!
    disabled_on = disabled_account.reload.disabled_at.to_date

    create_balance(account: active_account, date: disabled_on - 1.day, balance: 1_000)
    create_balance(account: disabled_account, date: disabled_on - 1.day, balance: 20_000)

    result = Assistant::Function::GetBalanceSheet.new(user).call(
      "start_date" => (disabled_on - 1.day).iso8601,
      "end_date" => disabled_on.iso8601,
      "interval" => "1 day"
    )

    values = result[:net_worth][:monthly_history][:values]

    assert_equal [ 21_000.0, 1_000.0 ], values
  end

  private
    def captured_history_account_ids(user)
      calls = []
      series = stub(start_date: 30.days.ago.to_date, end_date: Date.current, interval: "1 day", values: [])

      Balance::ChartSeriesBuilder.stubs(:new).with { |kwargs| calls << kwargs[:account_ids].sort; true }
        .returns(stub(balance_series: series))

      Assistant::Function::GetBalanceSheet.new(user).call("period" => "last_30_days", "interval" => "1 day")

      assert_equal 3, calls.size, "expected one history series each for net worth, assets and liabilities"
      { net_worth: calls[0], assets: calls[1], liabilities: calls[2] }
    end
end
