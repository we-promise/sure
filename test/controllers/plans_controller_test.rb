require "test_helper"

class PlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    ensure_tailwind_build
  end

  test "redirects users without preview access to budgets" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get plan_url

    assert_redirected_to budgets_path
  end

  test "renders budget and goals summary cards with drill-in links" do
    get plan_url

    assert_response :success
    assert_match I18n.t("plans.budget_card.title"), response.body
    assert_match I18n.t("plans.goals_card.title"), response.body
    assert_select "a[href=?]", budget_path(Budget.date_to_param(Date.current))
    assert_select "a[href=?]", goals_path
  end

  test "lists active goals with links to their detail pages" do
    get plan_url

    assert_response :success
    goal = goals(:vacation_italy)
    assert_match goal.name, response.body
    assert_select "a[href=?]", goal_path(goal)
  end

  test "shows the goals empty state when the family has no goals" do
    @user.family.goals.destroy_all

    get plan_url

    assert_response :success
    assert_match I18n.t("goals.empty_state.body"), response.body
  end

  test "shows the budget setup CTA when the month is uninitialized" do
    budgets(:one).update!(budgeted_spending: nil)

    get plan_url

    assert_response :success
    assert_match I18n.t("plans.budget_card.empty_body"), response.body
    assert_select "a[href=?]", edit_budget_path(Budget.date_to_param(Date.current))
  end
end
