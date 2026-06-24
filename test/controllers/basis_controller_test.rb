require "test_helper"

class BasisControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
    ensure_tailwind_build
  end

  test "redirects users without preview access" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    get basis_path

    assert_redirected_to root_path
    assert_match(/preview/i, flash[:alert])
  end

  test "renders basis page for preview-enabled users" do
    get basis_path

    assert_response :success
    assert_match(/Basis/i, response.body)
    assert_select "a[href='#{basis_path}']"
  end

  test "renders empty state when no snapshots exist" do
    get basis_path

    assert_response :success
    assert_match(/No basis snapshots yet/i, response.body)
  end

  test "renders chart payload and four toggles when snapshots exist" do
    BasisTradeSnapshot.create!(
      family: @user.family,
      recorded_at: Time.zone.parse("2026-06-20 12:00:00"),
      spot_leg_cents: 1_500_000,
      short_leg_cents: -25_000,
      funding_accrued_cents: 12_000,
      rewards_accrued_cents: 4_000,
      currency: "USD"
    )

    get basis_path

    assert_response :success
    assert_select "[data-controller='basis-chart']"
    assert_select "[data-basis-chart-payload-value]"
    assert_match(/weETH Spot/i, response.body)
    assert_match(/Perps Short/i, response.body)
    assert_match(/Funding/i, response.body)
    assert_match(/Rewards/i, response.body)
  end
end
