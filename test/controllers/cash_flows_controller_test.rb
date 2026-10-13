require "test_helper"

class CashFlowsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    @dates = { start_date: "2024-02-01", end_date: "2024-02-29" }
  end

  test "requires a browser session even when an API key is supplied" do
    get dashboard_cash_flow_path, params: @dates, headers: { "X-Api-Key" => api_key.display_key }
    assert_redirected_to new_session_path
  end

  test "requires the current user's preview opt-in" do
    sign_in @user
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    users(:family_member).update!(preferences: { "preview_features_enabled" => true })
    get dashboard_cash_flow_path, params: @dates
    assert_redirected_to root_path
  end

  test "retains ordinary onboarding and inactive-session checks" do
    sign_in @user
    @user.update!(onboarded_at: nil)
    get dashboard_cash_flow_path, params: @dates
    assert_redirected_to onboarding_path
    @user.update_column(:active, false)
    get dashboard_cash_flow_path, params: @dates
    assert_redirected_to new_session_path
  end

  test "matches the API graph with family timezone and finance-account scope" do
    @user.family.update!(timezone: "Pacific Time (US & Canada)")
    own = @user.family.accounts.create!(name: "Own", owner: @user, currency: "USD", balance: 0, accountable: Depository.new)
    other = @user.family.accounts.create!(name: "Excluded", owner: users(:family_member), currency: "USD", balance: 0, accountable: Depository.new)
    other.account_shares.create!(user: @user, permission: "read_only", include_in_finances: false)
    create_transaction(account: own, amount: 12, date: Date.new(2024, 2, 1))
    create_transaction(account: other, amount: 900, date: Date.new(2024, 2, 1))
    unrelated = users(:empty).family.accounts.create!(name: "Other family", currency: "USD", balance: 0, accountable: Depository.new)
    create_transaction(account: unrelated, amount: 700, date: Date.new(2024, 2, 1))
    sign_in @user
    key = api_key
    IncomeStatement.any_instance.expects(:daily_expense_series).never
    travel_to Time.utc(2024, 3, 1, 1) do
      get dashboard_cash_flow_path, params: @dates
      assert_response :success
      assert_equal "private, no-store", response.headers["Cache-Control"]
      graph = response.parsed_body
      assert_equal "2024-02-29", graph["as_of"]
      assert_equal "America/Los_Angeles", graph["time_zone"]
      assert_equal "12.0", graph.dig("sankey", "spending")
      get "/api/v1/cash_flow", params: @dates.merge(view: "sankey"), headers: { "X-Api-Key" => key.display_key }
      assert_response :success
      assert_equal graph, response.parsed_body
    end
  end

  test "rejects incomplete malformed and reversed date ranges" do
    sign_in @user
    [ {}, { start_date: "2024-01-01" }, { start_date: "2024-02-30", end_date: "2024-03-01" },
      { start_date: "2024-2-1", end_date: "2024-03-01" }, { start_date: "2024-03-01", end_date: "2024-02-01" },
      { start_date: [ "2024-01-01" ], end_date: "2024-03-01" } ].each do |dates|
      get dashboard_cash_flow_path, params: dates
      assert_response :unprocessable_entity
      assert_equal "invalid_period", response.parsed_body["error"]
    end
  end

  test "preserves explicit range bounds and empty graphs" do
    sign_in @user
    get dashboard_cash_flow_path, params: { start_date: "1900-01-01", end_date: "1900-01-02" }
    assert_response :success
    assert_empty response.parsed_body.dig("sankey", "nodes")
    get dashboard_cash_flow_path, params: { start_date: "2099-01-01", end_date: "2099-01-02" }
    assert_response :success
    assert_equal "2099-01-02", response.parsed_body.dig("period", "end_date")
  end

  test "uses the impersonated browser identity without adopting API credentials" do
    target = users(:family_member)
    target.update!(preferences: { "preview_features_enabled" => true })
    target.family.update!(currency: "JPY")
    sign_in users(:sure_support_staff)
    post join_impersonation_sessions_path, params: { impersonation_session_id: impersonation_sessions(:in_progress).id }
    get dashboard_cash_flow_path, params: @dates, headers: { "X-Api-Key" => "not-used-for-browser-auth" }
    assert_response :success
    assert_equal "JPY", response.parsed_body["currency"]
  end

  private
    def api_key
      ApiKey.create!(user: @user, name: "Graph Read", scopes: [ "read" ],
        display_key: "test_ro_#{SecureRandom.hex(8)}", source: "mobile")
    end
end
