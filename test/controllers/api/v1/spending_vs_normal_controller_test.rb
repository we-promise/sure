require "test_helper"

class Api::V1::SpendingVsNormalControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.api_keys.active.destroy_all
    @auth = ApiKey.create!(user: @user, name: "Reports Read", scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}", source: "mobile")
    Redis.new.del("api_rate_limit:#{@auth.id}")
  end

  test "requires authentication" do
    get "/api/v1/spending_vs_normal"
    assert_response :unauthorized
  end

  test "defaults to the current month to date" do
    travel_to Date.new(2024, 3, 15) do
      get "/api/v1/spending_vs_normal", headers: api_headers(@auth)

      assert_response :success
      assert_equal({ "start_date" => "2024-03-01", "end_date" => "2024-03-15" }, response.parsed_body["period"])
      assert response.parsed_body["in_progress"]
      assert_equal "private, no-store", response.headers["Cache-Control"]
    end
  end

  test "returns the period's spending per category against normal" do
    @user.family.entries.where(entryable_type: "Transaction").destroy_all
    account = accounts(:depository)
    category = categories(:food_and_drink)
    create_transaction(account: account, amount: 120, category: category, date: Date.new(2024, 2, 10))
    create_transaction(account: account, amount: 60, category: category, date: Date.new(2023, 11, 10))

    get "/api/v1/spending_vs_normal", params: { start_date: "2024-02-01", end_date: "2024-02-29" }, headers: api_headers(@auth)

    assert_response :success
    body = response.parsed_body
    food = body["categories"].find { |c| c["id"] == category.id }
    assert_equal "120.0", food["total"]
    # The 60 in the baseline, scaled from the baseline's length to February's 29 days
    baseline = body["baseline_period"]
    baseline_days = (Date.iso8601(baseline["end_date"]) - Date.iso8601(baseline["start_date"])).to_i + 1
    assert_equal "2024-01-31", baseline["end_date"]
    assert_in_delta 60.0 * 29 / baseline_days, food["normal"].to_f, 0.0001
    assert body["comparable"]
    assert_not body["in_progress"]
  end

  test "without enough history there is no baseline or normal" do
    category = categories(:food_and_drink)
    family = @user.family
    family.entries.where(entryable_type: "Transaction").destroy_all
    create_transaction(account: accounts(:depository), amount: 50, category: category, date: Date.new(2024, 2, 10))

    get "/api/v1/spending_vs_normal", params: { start_date: "2024-02-01", end_date: "2024-02-29" }, headers: api_headers(@auth)

    assert_response :success
    body = response.parsed_body
    assert_equal false, body["comparable"]
    assert_nil body["baseline_period"]
    assert_nil body["normal_total"]
    assert_nil body["categories"].find { |c| c["id"] == category.id }["normal"]
  end

  test "rejects invalid periods" do
    [ { start_date: "2024-02-01" }, { start_date: "2024-03-01", end_date: "2024-02-01" }, { start_date: "nope", end_date: "2024-02-01" } ].each do |params|
      get "/api/v1/spending_vs_normal", params: params, headers: api_headers(@auth)

      assert_response :unprocessable_entity
      assert_equal "invalid_period", response.parsed_body["error"]
    end
  end
end
