require "test_helper"

class Api::V1::PaycheckPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @other = users(:family_member)
    @user.api_keys.active.destroy_all
    @auth = ApiKey.create!(user: @user, name: "Paycheck Plans Read", scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}", source: "mobile")
    Redis.new.del("api_rate_limit:#{@auth.id}")
  end

  def build_money_map
    bob_checking = accounts(:depository) # owner: @user
    jakob_checking = @family.accounts.create!(name: "Jakob Checking", owner: @other,
      currency: "USD", balance: 0, accountable: Depository.new)
    jakob_fun = @family.accounts.create!(name: "Jakob Fun", owner: @other,
      currency: "USD", balance: 0, accountable: Depository.new)

    bob_payroll = create_income_series(account: bob_checking, name: "Bob Payroll", amount: 900)
    jakob_payroll = create_income_series(account: jakob_checking, name: "Jakob Payroll", amount: 100)

    IncomeAccountAllocation.create!(family: @family, income_series: bob_payroll,
      account: bob_checking, mode: "leftover")
    IncomeAccountAllocation.create!(family: @family, income_series: bob_payroll,
      account: jakob_checking, mode: "percent", value: 0.5)
    IncomeAccountAllocation.create!(family: @family, income_series: jakob_payroll,
      account: bob_checking, mode: "specific", value: 50)
    # jakob's remainder lands in his own fun account so the pooled leftover is
    # (900 + 100) across the two paychecks.
    IncomeAccountAllocation.create!(family: @family, income_series: jakob_payroll,
      account: jakob_fun, mode: "leftover")

    # netflix_subscription (15.99/month from bob_checking) is the obligation.
    settings = FamilyPlanSettings.for_family(@family)
    settings.leftover_distribution = "equal_split"
    settings.save!
    [ bob_payroll, jakob_payroll, bob_checking, jakob_checking ]
  end

  def create_income_series(account:, name:, amount:)
    series = @family.recurring_transactions.create!(
      name: name,
      account: account,
      amount: amount,
      currency: "USD",
      expected_day_of_month: 6,
      last_occurrence_date: Date.new(2026, 9, 6),
      next_expected_date: Date.new(2026, 12, 20),
      status: "active",
      bill_type: "income",
      manual: true
    )
    # House pattern (get_paycheck_plan_test): drop the auto-generated
    # occurrences, then create the exact paychecks the test needs.
    series.recurring_occurrences.destroy_all
    [ Date.new(2026, 11, 6), Date.new(2026, 11, 20) ].each do |date|
      series.recurring_occurrences.create!(family: @family, due_on: date,
        original_due_on: date, currency: "USD", expected_amount: amount,
        status: "scheduled")
    end
    series
  end

  test "requires authentication" do
    get "/api/v1/families/#{@family.id}/paycheck-plans"
    assert_response :unauthorized
  end

  test "non-members of the family are denied" do
    other_user = users(:empty)
    other_user.api_keys.active.destroy_all
    other_key = ApiKey.create!(user: other_user, name: "Other Read", scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}", source: "mobile")
    Redis.new.del("api_rate_limit:#{other_key.id}")
    get "/api/v1/families/#{@family.id}/paycheck-plans", headers: api_headers(other_key)
    assert_response :forbidden
    assert_equal "forbidden", response.parsed_body["error"]
  end

  test "malformed family ids are not found" do
    get "/api/v1/families/not-a-uuid/paycheck-plans", headers: api_headers(@auth)
    assert_response :not_found
  end

  test "rejects invalid months" do
    [ "2026-13", "2026-11-05", "not-a-month", "2026-1", "" ].each do |month|
      get "/api/v1/families/#{@family.id}/paycheck-plans", params: { month: month },
        headers: api_headers(@auth)
      assert_response :unprocessable_entity
      assert_equal "invalid_month", response.parsed_body["error"]
    end
  end

  test "captures a DebugLogEntry when the month is rejected" do
    assert_difference -> { DebugLogEntry.where(category: "paycheck_planner", family: @family).count }, 1 do
      get "/api/v1/families/#{@family.id}/paycheck-plans", params: { month: "not-a-month" },
        headers: api_headers(@auth)
    end
    assert_response :unprocessable_entity
    assert_equal "invalid_month", response.parsed_body["error"]

    entry = DebugLogEntry.where(category: "paycheck_planner", family: @family).recent.first
    assert_equal "warn", entry.level
    assert_equal "Api::V1::PaycheckPlansController", entry.source
    assert_equal "not-a-month", entry.metadata["requested_month"]
  end

  test "defaults to the current month" do
    travel_to Date.new(2026, 11, 15) do
      get "/api/v1/families/#{@family.id}/paycheck-plans", headers: api_headers(@auth)
      assert_response :success
      assert_equal "2026-11-01", response.parsed_body["month"]
    end
  end

  test "resolves the family money map for the month" do
    bob_payroll, jakob_payroll, bob_checking, jakob_checking = build_money_map
    assert_equal "Bob Payroll", bob_payroll.name
    get "/api/v1/families/#{@family.id}/paycheck-plans",
      params: { month: "2026-11" }, headers: api_headers(@auth)
    assert_response :success
    body = response.parsed_body

    assert_equal "2026-11-01", body["month"]
    assert_equal 4, body["total_paychecks"]
    assert_equal [ "2026-11-06", "2026-11-20" ], body["paycheck_dates"]

    depository = body["accounts"].find { |a| a["id"] == bob_checking.id }
    assert_equal "15.99", depository["required_month"] # netflix obligation
    assert_equal "4.00", depository["required_per_paycheck"] # 15.99 / 4, 2dp

    paycheck = body["paychecks"].find { |p| p["date"] == "2026-11-06" }
    assert_equal "1000.00", paycheck["total_income"]
    assert_equal "500.00", paycheck["by_account"][bob_checking.id] # 450 leftover + 50 specific
    assert_equal "450.00", paycheck["by_account"][jakob_checking.id] # 50% of 900
    leftover_row = paycheck["allocations"].find { |a| a["mode"] == "leftover" && a["account_id"] == bob_checking.id }
    assert_equal "450.00", leftover_row["amount"]
    assert_not leftover_row["shortfall"]

    attr = body["leftover_attribution"]
    assert_equal "equal_split", attr["distribution"]
    assert_equal "1000.00", attr["pooled_month"] # (900 + 100) across the two paychecks
    assert_equal "250.00", attr["pooled_per_paycheck"]
    bob = attr["by_partner"].find { |p| p["user_id"] == @user.id }
    jakob = attr["by_partner"].find { |p| p["user_id"] == @other.id }
    assert_equal "0.5000", bob["weight"]
    assert_equal "500.00", bob["fun_money_month"]
    assert_equal "900.00", bob["actual_leftover_month"]
    assert_equal "100.00", jakob["actual_leftover_month"]

    delta = body["delta"]
    assert_equal "500.00", delta["target_month"]
    assert_equal "800.00", delta["spread_month"]
    assert_equal "400.00", delta["by_partner"].find { |p| p["user_id"] == @user.id }["delta_month"]

    fix = body["suggested_fix"]
    assert_equal @user.id, fix["user_id"]
    assert_equal jakob_checking.id, fix["account_id"]
    assert_equal "0.5000", fix["current_percent"]
    assert_equal "0.7222", fix["suggested_percent"] # 0.5 + 400/1800
    assert_equal "500.00", fix["new_leftover_month"]

    assert_equal [], body["shortfalls"]
  end
end
