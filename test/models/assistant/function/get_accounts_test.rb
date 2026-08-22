require "test_helper"

class Assistant::Function::GetAccountsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetAccounts.new(@user)
  end

  test "has correct name" do
    assert_equal "get_accounts", @fn.name
  end

  test "has a description" do
    assert_not_empty @fn.description
  end

  test "is not in strict mode" do
    refute @fn.to_definition[:strict]
  end

  test "returns account ids and omits the balance series by default" do
    result = @fn.call

    assert result[:accounts].any?

    result[:accounts].each do |account|
      assert account[:id].present?
      assert_not account.key?(:historical_balances)
    end
  end

  test "excludes hidden accounts" do
    hidden = @family.accounts.visible.first
    hidden.update!(status: "disabled")

    result = @fn.call

    assert_not_includes result[:accounts].map { |a| a[:id] }, hidden.id
  end

  test "includes a balance series bounded by the requested period when asked" do
    result = @fn.call({ "include_balance_series" => true, "series_period" => "last_30_days" })

    account = result[:accounts].first
    series = account[:historical_balances]

    assert series.present?
    assert series[:start_date] >= 30.days.ago.to_date
    assert_equal Date.current, series[:end_date]
    assert(series[:values].all? { |v| v.is_a?(Numeric) })
  end

  test "falls back to last_365_days for an unknown series period" do
    result = @fn.call({ "include_balance_series" => true, "series_period" => "bogus" })

    series = result[:accounts].first[:historical_balances]

    assert series[:start_date] >= 366.days.ago.to_date
  end

  test "an account starting beyond the period skips its series without failing the call" do
    future_account = @family.accounts.create!(
      name: "Future Start Account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    future_account.entries.create!(
      name: "Scheduled opening deposit",
      date: 30.days.from_now.to_date,
      amount: -100,
      currency: "USD",
      entryable: Transaction.new
    )

    result = @fn.call({ "include_balance_series" => true, "series_period" => "last_7_days" })

    assert_not result.key?(:error)

    future_payload = result[:accounts].find { |a| a[:id] == future_account.id }

    assert_not_nil future_payload
    assert_not future_payload.key?(:historical_balances)
    assert(result[:accounts].any? { |a| a.key?(:historical_balances) })
  end
end
