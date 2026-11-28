require "test_helper"

# The "Financial independence" card on the Plan hub.
class RetirementPlans::PlanCardTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    RetirementPlan.where(user: @user).delete_all
    sign_in @user
    ensure_tailwind_build
  end

  test "the Plan page shows the FI card, worked out from the viewer's spending, and links to the planner" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("1000"))
    IncomeStatement.any_instance.stubs(:median_income).returns(BigDecimal("3000"))
    RetirementPlan.create!(user: @user, safe_withdrawal_rate: BigDecimal("0.04"))

    get plan_url

    assert_select "#retirement-plan-summary [data-fi-number]", text: /\$300,000/
    assert_select "#retirement-plan-summary a[href='#{retirement_plan_path}']"
  end

  test "opening the Plan page writes no plan" do
    assert_no_difference "RetirementPlan.count" do
      get plan_url
    end
  end

  test "without a saved plan the card invites one and works out no figures" do
    RetirementPlan.any_instance.expects(:projection).never

    get plan_url

    assert_response :success
    assert_select "#retirement-plan-card [data-retirement-plan-empty] a[href='#{edit_retirement_plan_path}']"
    assert_select "#retirement-plan-summary", count: 0
  end

  test "with no spending to go on, the card asks for it instead of showing a figure" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("0"))
    IncomeStatement.any_instance.stubs(:median_income).returns(BigDecimal("0"))
    RetirementPlan.create!(user: @user)

    get plan_url

    assert_select "#retirement-plan-summary [data-fi-number]", count: 0
    assert_select "#retirement-plan-summary", text: /#{Regexp.escape(I18n.t("retirement_plans.summary.no_expenses"))}/
  end

  test "past independence the bar is full and the figure says how far past" do
    IncomeStatement.any_instance.stubs(:median_expense).returns(BigDecimal("1"))
    IncomeStatement.any_instance.stubs(:median_income).returns(BigDecimal("0"))
    RetirementPlan::Projection.any_instance.stubs(:current_assets).returns(BigDecimal("336"))
    RetirementPlan.create!(user: @user)

    get plan_url

    assert_select "#retirement-plan-summary [data-fi-bar][style*='inline-size: 100']"
    assert_select "#retirement-plan-summary [data-fi-progress]", text: /112%/
  end
end
