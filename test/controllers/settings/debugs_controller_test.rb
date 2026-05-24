require "test_helper"

class Settings::DebugsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build

    @entry = DebugLogEntry.create!(
      category: "security_price_fetch",
      level: "warn",
      message: "Could not fetch prices",
      source: "Security::Price::Importer",
      provider_key: "twelve_data",
      family: families(:dylan_family),
      account: accounts(:depository),
      user: users(:family_admin),
      metadata: { ticker: "AAPL" }
    )
  end

  test "super admins can view debug log" do
    sign_in users(:sure_support_staff)

    get settings_debug_url

    assert_response :success
    assert_match "Debug event log", response.body
    assert_match @entry.message, response.body
  end

  test "non super admins are redirected" do
    sign_in users(:family_admin)

    get settings_debug_url

    assert_redirected_to root_url
  end

  test "filters by provider key" do
    sign_in users(:sure_support_staff)

    DebugLogEntry.create!(
      category: "security_price_fetch",
      level: "warn",
      message: "Should be filtered out",
      source: "Security::Price::Importer",
      provider_key: "finnhub",
      family: families(:dylan_family),
      account: accounts(:depository),
      user: users(:family_admin),
      metadata: { ticker: "MSFT" }
    )

    get settings_debug_url, params: { provider_key: "twelve_data" }

    assert_response :success
    assert_match @entry.message, response.body
    refute_match "Should be filtered out", response.body
  end

  test "ignores invalid uuid filters" do
    sign_in users(:sure_support_staff)

    get settings_debug_url, params: { family_id: "not-a-uuid" }

    assert_response :success
    assert_match @entry.message, response.body
  end
end
