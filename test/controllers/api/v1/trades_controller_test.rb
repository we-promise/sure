# frozen_string_literal: true

require "test_helper"

class Api::V1::TradesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @investment_account = accounts(:investment)
    @non_trade_account = accounts(:depository)
    @security = securities(:aapl)
    @trade = trades(:one)

    # Extra trade in a different account/date to exercise filters
    @other_trade = create_trade(
      account: accounts(:crypto),
      security: securities(:msft),
      qty: 4,
      price: 250,
      date: 30.days.ago.to_date
    )

    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "trades_rw_#{SecureRandom.hex(8)}",
      source: "web"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "trades_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")
  end

  test "should get index with valid API key" do
    get api_v1_trades_url, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data.key?("trades")
    assert response_data.key?("pagination")
    assert response_data["trades"].any? { |trade| trade["id"] == @trade.id }
  end

  test "should get index with read-only API key" do
    get api_v1_trades_url, headers: api_headers(@read_only_api_key)
    assert_response :success
  end

  test "should filter trades by account_id" do
    get api_v1_trades_url,
        params: { account_id: @investment_account.id },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data["trades"].all? { |trade| trade.dig("account", "id") == @investment_account.id }
  end

  test "should filter trades by date range" do
    get api_v1_trades_url,
        params: { start_date: 7.days.ago.to_date.to_s, end_date: Date.current.to_s },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data["trades"].none? { |trade| trade["id"] == @other_trade.id }
    assert response_data["trades"].all? do |trade|
      date = Date.parse(trade["date"])
      date >= 7.days.ago.to_date && date <= Date.current
    end
  end

  test "should return 422 for invalid date filter" do
    get api_v1_trades_url,
        params: { start_date: "not-a-date" },
        headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "should show trade with valid API key" do
    get api_v1_trade_url(@trade), headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal @trade.id, response_data["id"]
    assert_equal @trade.entry.account_id, response_data.dig("account", "id")
    assert_equal @trade.security_id, response_data.dig("security", "id")
  end

  test "should return 404 for non-existent trade" do
    get api_v1_trade_url(SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "should create trade with valid parameters" do
    assert_difference [ "Entry.count", "Trade.count" ], 1 do
      post api_v1_trades_url,
           params: {
             trade: {
               account_id: @investment_account.id,
               date: Date.current.to_s,
               qty: 2,
               price: 100.50,
               type: "buy",
               security_id: @security.id
             }
           },
           headers: api_headers(@api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal @investment_account.id, response_data.dig("account", "id")
    assert_equal @security.id, response_data.dig("security", "id")
  end

  test "should reject create with read-only API key" do
    post api_v1_trades_url,
         params: {
           trade: {
             account_id: @investment_account.id,
             date: Date.current.to_s,
             qty: 2,
             price: 100.50,
             type: "buy",
             security_id: @security.id
           }
         },
         headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should reject create when account does not support trades" do
    post api_v1_trades_url,
         params: {
           trade: {
             account_id: @non_trade_account.id,
             date: Date.current.to_s,
             qty: 2,
             price: 100.50,
             type: "buy",
             security_id: @security.id
           }
         },
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "should return 404 when create account is not found" do
    post api_v1_trades_url,
         params: {
           trade: {
             account_id: SecureRandom.uuid,
             date: Date.current.to_s,
             qty: 2,
             price: 100.50,
             type: "buy",
             security_id: @security.id
           }
         },
         headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "should reject create when type is missing" do
    post api_v1_trades_url,
         params: {
           trade: {
             account_id: @investment_account.id,
             date: Date.current.to_s,
             qty: 2,
             price: 100.50,
             security_id: @security.id
           }
         },
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "should reject create when security identifier is missing" do
    post api_v1_trades_url,
         params: {
           trade: {
             account_id: @investment_account.id,
             date: Date.current.to_s,
             qty: 2,
             price: 100.50,
             type: "buy"
           }
         },
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "should reject create with non numeric qty and price" do
    post api_v1_trades_url,
         params: {
           trade: {
             account_id: @investment_account.id,
             date: Date.current.to_s,
             qty: "abc",
             price: "xyz",
             type: "buy",
             security_id: @security.id
           }
         },
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity

    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["message"], "valid numbers"
  end

  test "should update trade with valid parameters" do
    patch api_v1_trade_url(@trade),
          params: {
            trade: {
              qty: 12,
              price: 220.75,
              type: "buy"
            }
          },
          headers: api_headers(@api_key)
    assert_response :success

    @trade.reload
    assert_equal 12.to_d, @trade.qty
    assert_equal 220.75.to_d, @trade.price
  end

  test "should reject update with read-only API key" do
    patch api_v1_trade_url(@trade),
          params: { trade: { qty: 12, price: 220.75, type: "buy" } },
          headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should return 404 for update of non-existent trade" do
    patch api_v1_trade_url(SecureRandom.uuid),
          params: { trade: { qty: 12, price: 220.75, type: "buy" } },
          headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "should destroy trade" do
    trade_to_delete = create_trade(
      account: @investment_account,
      security: @security,
      qty: 1,
      price: 50
    )

    assert_difference [ "Entry.count", "Trade.count" ], -1 do
      delete api_v1_trade_url(trade_to_delete), headers: api_headers(@api_key)
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal "Trade deleted successfully", response_data["message"]
  end

  test "should reject destroy with read-only API key" do
    delete api_v1_trade_url(@trade), headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should return 404 for destroy of non-existent trade" do
    delete api_v1_trade_url(SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "should reject requests without API key" do
    get api_v1_trades_url
    assert_response :unauthorized
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end

    def create_trade(account:, security:, qty:, price:, date: Date.current.to_date)
      signed_qty = qty.to_d
      trade = Trade.new(
        security: security,
        qty: signed_qty,
        price: price,
        currency: account.currency,
        investment_activity_label: signed_qty.negative? ? "Sell" : "Buy"
      )

      entry = account.entries.create!(
        name: Trade.build_name(signed_qty.negative? ? "sell" : "buy", signed_qty.abs, security.ticker),
        date: date,
        amount: signed_qty * price.to_d,
        currency: account.currency,
        entryable: trade
      )

      entry.trade
    end
end
