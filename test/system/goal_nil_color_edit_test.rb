require "application_system_test_case"

class GoalNilColorEditTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(
      preferences: (@user.preferences || {}).merge("preview_features_enabled" => true),
      show_ai_sidebar: false
    )
    sign_in @user
  end

  test "a goal with no color can still be edited and saved" do
    family = @user.family
    account = family.accounts.create!(accountable: Depository.new, name: "Livret",
                                      currency: family.currency, balance: 4_200)
    goal = family.goals.create!(
      name: "Précaution", target_amount: 1_000, currency: family.currency, color: nil
    ) { |g| g.goal_accounts.build(account: account) }

    assert_nil goal.color

    visit edit_goal_path(goal)
    fill_in I18n.t("goals.form.fields.name"), with: "Renamed"
    click_on I18n.t("goals.form.save")
    sleep 0.6

    assert_current_path goal_path(goal)
    goal.reload
    assert_equal "Renamed", goal.name
    assert goal.color.present?, "the goal still has no color after saving through the form"
  end
end
