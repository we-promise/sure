require "application_system_test_case"

class GoalMultiCurrencyTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @usd = @user.family.accounts.create!(name: "Dollar reserve", accountable: Depository.new, currency: "USD", balance: 500)
    @eur = @user.family.accounts.create!(name: "Euro reserve", accountable: Depository.new, currency: "EUR", balance: 1_000)
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.2)
  end

  test "create a goal backed by mixed currencies and show the converted total" do
    sign_in @user
    visit goals_path
    click_link I18n.t("goals.index.new_goal")

    within "turbo-frame#modal" do
      fill_in I18n.t("goals.form.fields.name"), with: "Travel reserve"
      fill_in I18n.t("goals.form.fields.target_amount"), with: "2000"
      check "goal_account_ids_#{@usd.id}"
      check "goal_account_ids_#{@eur.id}"
      click_button I18n.t("goals.form.create")
    end

    assert_text "Travel reserve"
    goal = @user.family.goals.find_by!(name: "Travel reserve")
    assert_current_path goal_path(goal)
    assert_equal "USD", goal.currency
    assert_equal 1_700, goal.current_balance
    assert_text Money.new(1_700, "USD").format(precision: 0)
    assert_text Money.new(1_000, "EUR").format(precision: 0)
    assert_text I18n.t("goals.show.funding_accounts.converted", amount: Money.new(1_200, "USD").format(precision: 0))

    if ENV["GOAL_CURRENCY_SCREENSHOT"] == "true"
      page.current_window.resize_to(2_000, 1_400)
      find("div.space-y-4.pb-6").native.save_screenshot(Rails.root.join("tmp/screenshots/goal-multi-currency.png").to_s)
    end
  end
end
