require "test_helper"

class Assistant::Function::ProjectCashBalanceTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @account.update!(balance: 1_000, currency: "USD")
    @family.recurring_transactions.destroy_all
    @fn = Assistant::Function::ProjectCashBalance.new(@user)
  end

  def call(**params)
    @fn.call({ "account_ids" => [ @account.id ] }.merge(params.transform_keys(&:to_s)))
  end

  def declare_series(name:, amount:, day:, bill_type: "bill")
    @family.recurring_transactions.create!(
      name: name, amount: amount, currency: "USD", account: @account,
      bill_type: bill_type, manual: true, status: "active",
      expected_day_of_month: day,
      anchor_date: Date.current.beginning_of_month + (day - 1),
      last_occurrence_date: Date.current - 1.month,
      next_expected_date: Date.current.beginning_of_month.next_month + (day - 1)
    )
  end

  test "has correct name and is not strict" do
    assert_equal "project_cash_balance", @fn.name
    refute @fn.to_definition[:strict]
  end

  test "returns a dated low point and a daily series by default" do
    result = call(horizon_days: 30)

    assert_equal 30, result[:horizon_days]
    assert result[:low_point][:date].present?
    assert result[:low_point][:balance_formatted].present?
    assert_equal 31, result[:daily_balances][:values].size
    assert_equal Date.current, result[:daily_balances][:start_date]
  end

  test "omits the daily series on request to save tokens" do
    result = call(horizon_days: 30, include_daily_series: false)

    assert_not result.key?(:daily_balances)
    assert result[:low_point].present?
  end

  test "counts declared income in the projection" do
    declare_series(name: "Salary", amount: -3_000, day: 28, bill_type: "income")

    result = call(horizon_days: 60)

    assert_equal true, result[:assumptions][:declared_income]
    assert(result[:events].any? { |e| e[:direction] == "in" })
  end

  test "warns explicitly when the projection contains no income" do
    result = call(horizon_days: 30)

    assert(result[:warnings].any? { |w| w.include?("NO incoming") })
  end

  test "flags the recorded overdraft limit as its own threshold" do
    @account.depository.update!(overdraft_limit: 400)
    declare_series(name: "Big bill", amount: 6_000, day: 10)

    result = call(horizon_days: 60)
    labels = result[:breaches].map { |b| b[:threshold_label] }

    assert_includes labels, "overdraft_limit"
    overdraft = result[:breaches].find { |b| b[:threshold_label] == "overdraft_limit" }
    assert_equal(-400, overdraft[:threshold])
    assert overdraft[:first_crossed_on].present?
  end

  test "accepts an explicit threshold" do
    result = call(horizon_days: 30, thresholds: [ 999_999 ])

    assert_includes result[:breaches].map { |b| b[:threshold_label] }, "custom_1"
  end

  test "reports no breaches when nothing is crossed" do
    @account.update!(balance: 500_000)

    assert_empty call(horizon_days: 30)[:breaches]
  end

  test "lists the dated events driving the shape" do
    declare_series(name: "Rent", amount: 1_500, day: 5)

    events = call(horizon_days: 60)[:events]

    assert(events.any? { |e| e[:label] == "Rent" && e[:direction] == "out" })
  end

  test "says how many events it did not list rather than hiding them" do
    20.times { |i| declare_series(name: "Bill #{i}", amount: 10, day: (i % 28) + 1) }

    result = call(horizon_days: 365)
    note = result[:events].last

    assert note[:note].present?, "truncation must be stated"
    assert_match(/ARE counted in the balances/, note[:note])
  end

  test "clamps the horizon instead of accepting an absurd one" do
    assert_equal Cashflow::Projection::MAX_HORIZON_DAYS, call(horizon_days: 5_000)[:horizon_days]
  end

  test "scopes to the accounts the user can access" do
    member_fn = Assistant::Function::ProjectCashBalance.new(users(:family_member))

    result = member_fn.call("account_ids" => [ accounts(:investment).id ])

    assert_empty result[:assumptions][:accounts_included]
  end
end
