require "test_helper"

# The year-by-year planner and its milestones on the planner page.
class RetirementPlans::PlannerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    RetirementPlan.where(user: @user).delete_all
    sign_in @user
    ensure_tailwind_build
  end

  test "without a birth year the planner asks for one instead of showing a table" do
    RetirementPlan.create!(user: @user, retirement_date: Date.current.next_year(10))

    get retirement_plan_url

    assert_response :success
    assert_select "[data-planner-needs='birth_year']"
    assert_select "#retirement-planner-table", count: 0
  end

  test "a traditional plan without a retirement date asks for one" do
    RetirementPlan.create!(user: @user, birth_year: 1980)

    get retirement_plan_url

    assert_select "[data-planner-needs='retirement_date']"
  end

  test "a retirement after the end age leaves no years to plan, and the page says so" do
    RetirementPlan.create!(user: @user, birth_year: 1980, end_age: 60, retirement_date: Date.new(2045, 1, 1))

    get retirement_plan_url

    assert_response :success
    assert_select "[data-planner-needs='years']"
  end

  test "a traditional plan shows a row for every year to the end age, and whether the money lasts" do
    RetirementPlan.create!(user: @user, birth_year: 1980, end_age: 90, retirement_date: Date.new(2045, 1, 1))

    get retirement_plan_url

    assert_select "#retirement-planner-table tbody tr", count: 2070 - Date.current.year + 1
    assert_select "#retirement-planner-table tbody tr[data-year='2044']:not([data-retired])"
    assert_select "#retirement-planner-table tbody tr[data-year='2045'][data-retired]"
    assert_select "[data-planner-outcome]"
    assert_select "[data-planner-chart][data-controller='time-series-chart']"
  end

  test "the year the money runs out is the row that is flagged" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("0"))
    plan = RetirementPlan.create!(user: @user, birth_year: 1980, end_age: 90, retirement_date: Date.new(2045, 1, 1))
    plan.streams.create!(kind: "expense", name: "Living", annual_amount: 50_000, source: "manual")
    depletion = plan.simulation(as_of: Date.current).depletion_year
    assert depletion, "the fixture must run out of money"

    get retirement_plan_url

    assert_select "[data-planner-outcome='runs-out']"
    assert_select "#retirement-planner-table tbody tr.bg-warning\\/10", count: 1
    assert_select "#retirement-planner-table tbody tr.bg-warning\\/10[data-year='#{depletion}']"
  end

  test "a FIRE plan shows the earliest year on expected returns" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("0"))
    RetirementPlan.create!(user: @user, birth_year: 1980, mode: "fire")

    get retirement_plan_url

    assert_select "[data-planner-outcome='fire'][data-retirement-year='#{Date.current.year}']"
  end

  test "a FIRE plan that never lasts says so, and shows no table" do
    plan = RetirementPlan.create!(user: @user, birth_year: 1980, end_age: 90, mode: "fire")
    plan.streams.create!(kind: "expense", name: "Living", annual_amount: 10_000_000, source: "manual")

    get retirement_plan_url

    assert_select "[data-planner-outcome='fire-unreachable']"
    assert_select "#retirement-planner-table", count: 0
  end

  test "opening the planner seeds nothing and writes nothing" do
    RetirementPlan.create!(user: @user, birth_year: 1980, retirement_date: Date.new(2045, 1, 1))

    assert_no_difference [ "RetirementPlan.count", "RetirementPlan::Stream.count" ] do
      get retirement_plan_url
    end
    assert_nil RetirementPlan.find_by!(user: @user).streams_seeded_on
  end

  test "opening the planner without a saved plan creates none" do
    assert_no_difference "RetirementPlan.count" do
      get retirement_plan_url
    end
    assert_response :success
  end
end
