require "test_helper"

class Retirement::PensionSourcesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @user.family.update!(retirement_disabled: false)
    sign_in @user
    ensure_tailwind_build
    @plan = Goal::Retirement.for_owner(@user)
  end

  def valid_params
    { name: "State", kind: "state", country: "DE", pension_system: "de_grv",
      tax_treatment: "de_renten", payout_shape: "monthly_for_life",
      start_age: 67, amount: 1500, currency: "EUR" }
  end

  test "redirects when preview features disabled" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    get new_retirement_pension_source_url
    assert_redirected_to root_path
  end

  test "404 when family retirement disabled" do
    @user.family.update!(retirement_disabled: true)
    get new_retirement_pension_source_url
    assert_response :not_found
  end

  test "new renders the form" do
    get new_retirement_pension_source_url
    assert_response :success
  end

  test "edit renders the form" do
    get edit_retirement_pension_source_url(pension_sources(:de_grv_bob))
    assert_response :success
  end

  test "create adds a source to the owner's plan" do
    assert_difference -> { @plan.pension_sources.count }, 1 do
      post retirement_pension_sources_url, params: { pension_source: valid_params }
    end
    assert_redirected_to retirement_path
  end

  test "invalid create re-renders unprocessable" do
    post retirement_pension_sources_url, params: { pension_source: valid_params.merge(name: "") }
    assert_response :unprocessable_entity
  end

  test "destroy removes a source" do
    source = @plan.pension_sources.create!(valid_params)
    assert_difference -> { @plan.pension_sources.count }, -1 do
      delete retirement_pension_source_url(source)
    end
    assert_redirected_to retirement_path
  end
end
