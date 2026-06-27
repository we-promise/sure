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

  test "renders live basis balances when direct sources are configured" do
    @user.family.update!(
      basis_long_address: "0x1111111111111111111111111111111111111111",
      basis_long_token_addresses: "0x2222222222222222222222222222222222222222",
      basis_lighter_address: "0x3333333333333333333333333333333333333333"
    )

    BasisTrade::OptimismWalletValuator.any_instance.stubs(:value).returns(
      total_value: BigDecimal("1500.25"),
      tokens: [ { symbol: "weETH", balance: BigDecimal("0.75") } ]
    )
    Provider::Lighter.any_instance.stubs(:total_account_value_for_l1_address).returns(
      total_account_value: BigDecimal("980.10"),
      accounts: [ { index: "17", total_asset_value: BigDecimal("980.10") } ]
    )

    get basis_path

    assert_response :success
    assert_match(/Live balances/i, response.body)
    assert_match(/Spot wallet balances/i, response.body)
    assert_match(/Lighter account values/i, response.body)
    assert_match(/weETH/i, response.body)
    assert_match(/Account 17/i, response.body)
  end

  test "renders basis configuration guidance when direct sources are not configured" do
    get basis_path

    assert_response :success
    assert_match(/Settings → Preferences/i, response.body)
  end

  test "renders live basis error when direct source refresh fails" do
    @user.family.update!(basis_long_address: "0x1111111111111111111111111111111111111111")
    BasisTrade::LiveSnapshotBuilder.any_instance.stubs(:call).returns(
      BasisTrade::LiveSnapshotBuilder::Result.new(configured: true, error: "boom")
    )

    get basis_path

    assert_response :success
    assert_match(/Live balance refresh failed: boom/i, response.body)
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
