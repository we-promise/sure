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
end
