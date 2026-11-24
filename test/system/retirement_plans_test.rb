require "application_system_test_case"

# The planner's critical path in a browser: the planner page and the
# settings modal.
class RetirementPlansTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true), show_ai_sidebar: false)
    RetirementPlan.where(user: @user).delete_all
    sign_in @user
  end

  test "a user sets up a plan from the planner's settings" do
    visit retirement_plan_path

    assert_selector "[data-planner-needs='birth_year']"

    click_link I18n.t("retirement_plans.show.settings"), match: :first
    within("dialog") do
      fill_in "retirement_plan[birth_year]", with: "1985"
      find("input[name='retirement_plan[retirement_date]']").set(Date.new(2045, 1, 1))
      click_button I18n.t("retirement_plans.form.save")
    end

    assert_selector "#retirement-planner-table tr[data-year='2045'][data-retired]"
    assert_selector "[data-planner-outcome]"
  end
end
