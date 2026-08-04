require "test_helper"

class BudgetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    ensure_tailwind_build
  end

  test "index redirects to the current month budget" do
    get budgets_url

    assert_redirected_to budget_path(Budget.date_to_param(Date.current))
  end

  test "show renders the budget page" do
    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
  end

  test "breadcrumbs include the Plan hub for preview users" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", plan_path, minimum: 1
  end

  test "renders no Plan links without preview features" do
    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", plan_path, count: 0
    assert_select "a[href=?]", budgets_path, minimum: 1
  end

  test "show renders a budget addressed by a plan-qualified param" do
    plan = budget_plans(:dylan_personal)

    get budget_url("#{plan.slug}-#{Budget.date_to_param(Date.current)}")

    assert_response :success
    assert_match plan.name, response.body
  end

  test "show 404s for an unknown plan slug" do
    get budget_url("ghost-#{Budget.date_to_param(Date.current)}")

    assert_response :not_found
  end

  test "header shows the plan switcher listing every plan" do
    plan = budget_plans(:dylan_personal)

    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", budget_path("#{plan.slug}-#{Budget.date_to_param(Date.current)}")
    assert_select "a[href=?]", new_budget_plan_path, minimum: 1
  end

  test "header omits the plan switcher for single-plan families" do
    budget_plans(:dylan_personal).destroy!

    get budget_url(Budget.date_to_param(Date.current))

    assert_response :success
    assert_select "a[href=?]", edit_budget_plan_path(budget_plans(:dylan_default)), count: 0
    # The picker footer still offers plan creation.
    assert_select "a[href=?]", new_budget_plan_path, minimum: 1
  end

  test "picker preserves plan context across year navigation" do
    plan = budget_plans(:dylan_personal)

    get picker_budgets_url(year: Date.current.year, plan: plan.slug)

    assert_response :success
    assert_select "a[href=?]", budget_path("#{plan.slug}-#{Budget.date_to_param(Date.current.beginning_of_year)}")
  end
end
