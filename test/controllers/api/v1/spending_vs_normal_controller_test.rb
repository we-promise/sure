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
      assert_equal "private, no-store", response.headers["Cache-Control"]
    end
  end

  test "returns the period's spending per category against normal" do
    account = accounts(:depository)
    category = categories(:food_and_drink)
    create_transaction(account: account, amount: 120, category: category, date: Date.new(2024, 2, 10))
    create_transaction(account: account, amount: 60, category: category, date: Date.new(2023, 11, 10))

    get "/api/v1/spending_vs_normal", params: { start_date: "2024-02-01", end_date: "2024-02-29" }, headers: api_headers(@auth)

    assert_response :success
    body = response.parsed_body
    food = body["categories"].find { |c| c["id"] == category.id }
    assert_equal "120.0", food["total"]
    assert_kind_of String, food["normal"]
    assert body["comparable"]
  end

  test "rejects invalid periods" do
    [ { start_date: "2024-02-01" }, { start_date: "2024-03-01", end_date: "2024-02-01" }, { start_date: "nope", end_date: "2024-02-01" } ].each do |params|
      get "/api/v1/spending_vs_normal", params: params, headers: api_headers(@auth)

      assert_response :unprocessable_entity
      assert_equal "invalid_period", response.parsed_body["error"]
    end
  end
end
