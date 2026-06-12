# frozen_string_literal: true

require "test_helper"

class Api::V1::TradesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @family = @admin.family
    @investment = accounts(:investment)
    @security = securities(:aapl)
    @trade_entry = entries(:trade)
    @trade = @trade_entry.entryable

    @member = users(:family_member)
    @member.api_keys.active.destroy_all
    @member_key = ApiKey.create!(
      user: @member,
      name: "Member RW",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_member_#{SecureRandom.hex(8)}"
    )

    @admin.api_keys.active.destroy_all
    @admin_read_key = ApiKey.create!(
      user: @admin,
      name: "Admin Read",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_admin_read_#{SecureRandom.hex(8)}"
    )
  end

  test "should reject index without API key" do
    get api_v1_trades_url
    assert_response :unauthorized
  end

  test "index excludes trades from inaccessible accounts" do
    get api_v1_trades_url, headers: api_headers(@member_key)

    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data.key?("trades")
    trade_ids = response_data.fetch("trades", []).map { |trade| trade["id"] }
    assert_not_includes trade_ids, @trade.id
  end

  test "should show trade with read access to account" do
    get api_v1_trade_url(@trade), headers: api_headers(@admin_read_key)

    assert_response :success
    assert_equal @trade.id, JSON.parse(response.body).dig("trade", "id")
  end

  test "should reject create with read-only API key" do
    post api_v1_trades_url,
         params: {
           trade: {
             account_id: @investment.id,
             type: "buy",
             date: Date.current,
             qty: 1,
             price: 100,
             currency: "USD",
             security_id: @security.id
           }
         },
         headers: api_headers(@admin_read_key)

    assert_response :forbidden
  end

  test "should not create trade on account without write permission" do
    assert_no_difference -> { Trade.count } do
      post api_v1_trades_url,
           params: {
             trade: {
               account_id: @investment.id,
               type: "buy",
               date: Date.current,
               qty: 1,
               price: 100,
               currency: "USD",
               security_id: @security.id
             }
           },
           headers: api_headers(@member_key)
    end

    assert_response :not_found
  end

  test "should not update trade on account without write permission" do
    patch api_v1_trade_url(@trade),
          params: { trade: { notes: "Blocked update" } },
          headers: api_headers(@member_key)

    assert_response :not_found
    assert_not_equal "Blocked update", @trade_entry.reload.notes
  end

  test "should not destroy trade on account without write permission" do
    assert_no_difference -> { Trade.count } do
      delete api_v1_trade_url(@trade), headers: api_headers(@member_key)
    end

    assert_response :not_found
    assert Trade.exists?(@trade.id)
  end
end
