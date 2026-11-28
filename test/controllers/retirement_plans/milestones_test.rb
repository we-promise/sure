require "test_helper"

# The milestones on the planner page.
class RetirementPlans::MilestonesTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    RetirementPlan.where(user: @user).delete_all
    sign_in @user
    ensure_tailwind_build
    # 1,000 a month of spending (an FI number of 300,000 at 4%) and 5,000 of
    # income, with 100,000 in the plan: 25% is already passed and the others
    # lie ahead, so both states render.
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("1000"))
    IncomeStatement.any_instance.stubs(:median_income).returns(BigDecimal("5000"))
    RetirementPlan.any_instance.stubs(:funding_total).returns(BigDecimal("100000"))
    @plan = RetirementPlan.create!(user: @user, birth_year: 1980, end_age: 90, retirement_date: Date.new(2046, 1, 1),
                                   safe_withdrawal_rate: BigDecimal("0.04"), savings_rate: BigDecimal("0.5"))
  end

  def expected
    @plan.milestones(as_of: Date.current).index_by(&:key)
  end

  test "each milestone is listed with the year the plan reaches it, or as reached" do
    get retirement_plan_url

    assert_equal %w[fi_25 fi_50 fi_75 fi_100 coast], expected.keys, "the fixture must produce all five"
    assert expected.values.any?(&:reached_already), "the fixture must include a milestone already reached"
    assert expected.values.any?(&:year), "the fixture must include a dated milestone"
    expected.each do |key, m|
      if m.reached_already
        assert_select "[data-milestone='#{key}'][data-milestone-reached]"
      else
        assert_select "[data-milestone='#{key}'][data-milestone-year='#{m.year}']"
      end
    end
  end

  test "the table flags the row of each milestone reached within the plan" do
    get retirement_plan_url

    dated = expected.values.select(&:year)
    assert_not_empty dated
    dated.each do |m|
      assert_select "#retirement-planner-table tr[data-year='#{m.year}'] [data-row-milestone='#{m.key}']"
    end
    assert_select "#retirement-planner-table [data-row-milestone]", count: dated.size
  end

  test "a plan in FIRE mode without a retirement date shows no Coast FI" do
    @plan.update!(mode: "fire", retirement_date: nil)

    get retirement_plan_url

    assert_select "[data-milestone='fi_50']"
    assert_select "[data-milestone='coast']", count: 0
  end

  test "without spending there is no FI number, and no milestones" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("0"))

    get retirement_plan_url

    assert_select "#retirement-planner-milestones", count: 0
  end
end
