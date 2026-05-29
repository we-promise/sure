require "test_helper"

class RetirementControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family.update!(retirement_disabled: false)
    sign_in @user
    ensure_tailwind_build
  end

  test "redirects when preview features disabled" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get retirement_url

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "404 when family retirement_disabled is true" do
    @family.update!(retirement_disabled: true)

    get retirement_url

    assert_response :not_found
  end

  test "200 when preview features and family flag both allow" do
    get retirement_url

    assert_response :success
    assert_match(/Retirement/i, response.body)
  end

  test "nav item rendered when preview enabled" do
    get root_url

    assert_select "a[href=?]", retirement_path
  end

  test "nav item hidden when preview disabled" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get root_url

    assert_select "a[href=?]", retirement_path, count: 0
  end

  test "nav item hidden when family retirement disabled" do
    @family.update!(retirement_disabled: true)

    get root_url

    assert_select "a[href=?]", retirement_path, count: 0
  end

  test "show renders the KPI section" do
    get retirement_url
    assert_response :success
    assert_select "#retirement_kpis"
  end

  test "show uses real translations, not humanized i18n keys" do
    get retirement_url
    assert_response :success
    assert_match I18n.t("retirement.show.sources_title"), response.body
    assert_no_match(/Sources Title/, response.body)
  end

  test "update persists retirement params" do
    patch retirement_url, params: { retirement: {
      birth_year: 1985, retire_age: 62, monthly_savings: 1500, target_spend: 2800, real_return_pct: 5
    } }

    assert_redirected_to retirement_path
    plan = Goal::Retirement.for_owner(@user)
    assert_equal "1985", plan.birth_year.to_s
    assert_equal "62", plan.retire_age.to_s
  end

  test "forecast streams KPIs without persisting" do
    Goal::Retirement.for_owner(@user).update!(retirement_params: { "birth_year" => 1980 })

    patch forecast_retirement_url,
      params: { retirement: { retire_age: 70 } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_match "retirement_kpis", response.body
    # transient: the slider value is not written back to the plan
    assert_nil Goal::Retirement.for_owner(@user).retire_age
  end
end
