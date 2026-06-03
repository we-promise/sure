require "application_system_test_case"

class RetirementTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @user.family.update!(retirement_disabled: false)
    sign_in @user
  end

  test "set up a plan and see the projection render" do
    visit retirement_path

    assert_selector "h1", text: I18n.t("retirement.show.title")
    assert_text I18n.t("retirement.kpis.set_birth_year_heading")

    fill_in "retirement[birth_year]", with: (Date.current.year - 40).to_s
    fill_in "retirement[retire_age]", with: "55"
    click_button I18n.t("retirement.what_if.save")

    # After persisting, the forecast is projectable: the KPI cards + the D3
    # glide chart render. (The KPI label is CSS-uppercased, so match the
    # rendered SVG + the KPI container rather than the case-folded label.)
    assert_selector "#retirement_kpis", wait: 5
    assert_selector "[data-controller='retirement-glide-chart'] svg", wait: 5
  end
end
