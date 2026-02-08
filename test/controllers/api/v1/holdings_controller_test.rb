# frozen_string_literal: true

require "test_helper"

class Api::V1::HoldingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:investment)
    @holding = holdings(:one)
    @security = securities(:aapl)

    @other_account = accounts(:crypto)
    @other_security = securities(:msft)
    @other_holding = Holding.create!(
      account: @other_account,
      security: @other_security,
      date: 30.days.ago.to_date,
      qty: 3,
      price: 100,
      amount: 300,
      currency: "USD"
    )

    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "holdings_rw_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "holdings_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")
  end

  test "should get index with valid API key" do
    get api_v1_holdings_url, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data.key?("holdings")
    assert response_data.key?("pagination")
    assert response_data["holdings"].any? { |holding| holding["id"] == @holding.id }
  end

  test "should get index with read-only API key" do
    get api_v1_holdings_url, headers: api_headers(@read_only_api_key)
    assert_response :success
  end

  test "should filter holdings by account_id" do
    get api_v1_holdings_url,
        params: { account_id: @account.id },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data["holdings"].all? { |holding| holding.dig("account", "id") == @account.id }
  end

  test "should filter holdings by security_id" do
    get api_v1_holdings_url,
        params: { security_id: @other_security.id },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal [ @other_holding.id ], response_data["holdings"].map { |holding| holding["id"] }
  end

  test "should filter holdings by date range" do
    get api_v1_holdings_url,
        params: { start_date: 7.days.ago.to_date.to_s, end_date: Date.current.to_s },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data["holdings"].all? do |holding|
      date = Date.parse(holding["date"])
      date >= 7.days.ago.to_date && date <= Date.current
    end
  end

  test "should return 422 for invalid date filter" do
    get api_v1_holdings_url,
        params: { start_date: "not-a-date" },
        headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "should show holding with valid API key" do
    get api_v1_holding_url(@holding), headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal @holding.id, response_data["id"]
    assert_equal @holding.account_id, response_data.dig("account", "id")
    assert_equal @holding.security_id, response_data.dig("security", "id")
  end

  test "should return 404 for non-existent holding" do
    get api_v1_holding_url(SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "should reject requests without API key" do
    get api_v1_holdings_url
    assert_response :unauthorized
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
