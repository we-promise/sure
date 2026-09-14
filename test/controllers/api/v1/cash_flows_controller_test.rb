require "test_helper"

class Api::V1::CashFlowsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper
  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @auth = ApiKey.create!(user: @user, name: "Summary Read", scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}", source: "mobile")
    Redis.new.del("api_rate_limit:#{@auth.id}")
  end

  test "requires authentication" do
    get "/api/v1/cash_flow"
    assert_response :unauthorized
  end

  test "supports read and read_write and defaults to family month" do
    @user.family.update!(timezone: "Pacific Time (US & Canada)")
    travel_to Time.utc(2024, 3, 1, 1) do
      %w[read read_write].each do |scope|
        @auth.update!(scopes: [ scope ])
        get "/api/v1/cash_flow", headers: api_headers(@auth)
        assert_response :success
        body = response.parsed_body
        assert_equal "2024-02-01", body["month"]
        assert_equal "2024-02-29", body["as_of"]
        assert_equal "America/Los_Angeles", body["time_zone"]
        assert_equal 29, body.dig("spending_comparison", "current").size
      end
    end
  end

  test "rejects invalid and future periods" do
    [ "2024-02-02", "2024-13-01", "not-a-date", "9999-01-01", "" ].each do |month|
      get "/api/v1/cash_flow", params: { month: month }, headers: api_headers(@auth)
      assert_response :unprocessable_entity
      assert_equal "invalid_month", response.parsed_body["error"]
    end
  end

  test "summary uses the authenticated user's finance account selection" do
    month = Date.new(2024, 2, 1)
    own = @user.family.accounts.create!(name: "Own", owner: @user, currency: "USD", balance: 0, accountable: Depository.new)
    other = @user.family.users.where.not(id: @user.id).first!
    excluded = @user.family.accounts.create!(name: "Read only share", owner: other, currency: "USD", balance: 0, accountable: Depository.new)
    excluded.account_shares.create!(user: @user, permission: "read_only", include_in_finances: false)
    create_transaction(account: own, amount: 12, date: month)
    create_transaction(account: excluded, amount: 900, date: month)
    get "/api/v1/cash_flow", params: { month: month.iso8601, include: "sankey" }, headers: api_headers(@auth)
    assert_response :success
    assert_equal "12.0", response.parsed_body.dig("sankey", "spending")
    assert_equal "12.0", response.parsed_body["spending"]
    assert_equal "12.0", response.parsed_body.dig("spending_comparison", "current_total")
  end

  test "graph is opt-in and date ranges do not calculate daily series" do
    get "/api/v1/cash_flow", headers: api_headers(@auth)
    assert_not response.parsed_body.key?("sankey")
    get "/api/v1/cash_flow", params: { include: "sankey" }, headers: api_headers(@auth)
    assert_response :success
    assert_equal "net_by_category", response.parsed_body.dig("sankey", "basis")
    IncomeStatement.any_instance.expects(:daily_expense_series).never
    get "/api/v1/cash_flow", params: { view: "sankey", start_date: "2000-01-01", end_date: "2024-02-29" }, headers: api_headers(@auth)
    assert_response :success
    assert_equal "2000-01-01", response.parsed_body.dig("period", "start_date")
    assert_not response.parsed_body.key?("spending_comparison")
  end

  test "rejects ambiguous or invalid graph ranges" do
    [ { start_date: "2024-01-01" }, { view: "sankey", start_date: "2024-01-01" },
      { view: "sankey", start_date: "2024-02-30", end_date: "2024-03-01" },
      { view: "sankey", start_date: "2024-02-01", end_date: "2024-01-01" },
      { view: "sankey", month: "2024-01-01", start_date: "2024-01-01", end_date: "2024-01-02" },
      { view: "invalid" }, { include: "invalid" } ].each do |query|
      get "/api/v1/cash_flow", params: query, headers: api_headers(@auth)
      assert_response :unprocessable_entity
    end
  end

  test "dashboard cookie can read only this endpoint and never overrides explicit credentials" do
    sign_in @user
    get "/api/v1/cash_flow", params: { view: "sankey" }
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    get "/api/v1/accounts"
    assert_response :unauthorized
    [ { "X-Api-Key" => "invalid" }, { "Authorization" => "Bearer invalid" }, { "X-Api-Key" => "" } ].each do |headers|
      get "/api/v1/cash_flow", headers: headers
      assert_response :unauthorized
    end
    @user.update_column(:active, false)
    get "/api/v1/cash_flow"
    assert_response :unauthorized
  end

  test "browser graph honors impersonation while API identity stays independent" do
    @auth.update!(user: users(:empty))
    sign_in users(:sure_support_staff)
    post join_impersonation_sessions_path, params: { impersonation_session_id: impersonation_sessions(:in_progress).id }
    family = users(:family_member).family
    family.update!(currency: "JPY")
    get "/api/v1/cash_flow", params: { view: "sankey" }
    assert_response :success
    assert_equal "JPY", response.parsed_body["currency"]
    get "/api/v1/cash_flow", params: { view: "sankey" }, headers: api_headers(@auth)
    assert_response :success
    assert_equal users(:empty).family.currency, response.parsed_body["currency"]
  end

  private
    def api_headers(auth)
      { "X-Api-Key" => auth.display_key }
    end
end
