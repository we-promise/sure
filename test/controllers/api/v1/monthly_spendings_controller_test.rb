require "test_helper"

class Api::V1::MonthlySpendingsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:empty)
    @user.update!(preferences: { "preview_features_enabled" => true })
    @user.api_keys.active.destroy_all
    @key = ApiKey.create!(user: @user, name: "Monthly Read", scopes: [ "read" ], display_key: "monthly_#{SecureRandom.hex(8)}", source: "mobile")
    Redis.new.del("api_rate_limit:#{@key.id}")
    @headers = { "X-Api-Key" => @key.display_key }
    @account = @user.family.accounts.create!(name: "Own", owner: @user, currency: "USD", balance: 0, accountable: Depository.new)
  end

  test "returns shared monthly results and private cache policy for read credentials" do
    create_transaction(account: @account, amount: 20, date: "2024-12-31")
    get "/api/v1/monthly_spending", params: { from: "2024-12-01", to: "2025-01-01" }, headers: @headers
    assert_response :success
    assert_equal "gross_expense", response.parsed_body["basis"]
    assert_equal "20.0", response.parsed_body["months"].first["total"]
    assert_equal "private, no-store", response.headers["Cache-Control"]
  end

  test "gate uses API identity rather than another household member or browser session" do
    @user.update!(preferences: { "preview_features_enabled" => false })
    sign_in users(:family_admin)
    get "/api/v1/monthly_spending", headers: @headers
    assert_response :forbidden
    get "/api/v1/monthly_spending"
    assert_response :unauthorized
  end

  test "explicit empty filters return zero and foreign IDs and malformed arrays are rejected" do
    create_transaction(account: @account, amount: 20, date: Date.current)
    get "/api/v1/monthly_spending", params: { account_ids: [ "" ] }, headers: @headers
    assert_response :success
    assert response.parsed_body["empty_selection"]
    assert response.parsed_body["months"].all? { |month| month["total"] == "0.0" }
    [ { account_ids: [ accounts(:depository).id ] }, { category_ids: "all" }, { from: "2020-01-01" }, { to: "invalid" } ].each do |query|
      get "/api/v1/monthly_spending", params: query, headers: @headers
      assert_response :unprocessable_entity
      assert_equal "invalid_selection", response.parsed_body["error"]
    end
  end

  test "uses the family timezone around month rollover" do
    @user.family.update!(timezone: "America/Los_Angeles")
    travel_to Time.utc(2025, 2, 1, 1, 0) do
      get "/api/v1/monthly_spending", headers: @headers
      assert_response :success
      assert_equal "2025-01-01", response.parsed_body.dig("period", "to")
      assert_equal "2025-01-31", response.parsed_body["as_of"]
    end
  end
end
