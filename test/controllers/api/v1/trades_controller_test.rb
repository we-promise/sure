# frozen_string_literal: true

require "test_helper"

class Api::V1::TradesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @member = users(:family_member)
    @private_trade = trades(:one)
    @private_account = accounts(:investment)
    @security = securities(:aapl)

    @shared_account = Account.create!(
      family: @member.family,
      owner: @admin,
      name: "Shared Investment Account",
      balance: 10_000,
      cash_balance: 5_000,
      currency: "USD",
      classification: "asset",
      accountable: Investment.create!,
      status: :active
    )
    AccountShare.create!(
      account: @shared_account,
      user: @member,
      permission: "read_only",
      include_in_finances: true
    )
    @shared_trade = @shared_account.entries.create!(
      name: "Buy 1 shares of AAPL",
      date: Date.current,
      amount: 200,
      currency: "USD",
      entryable: Trade.new(
        security: @security,
        qty: 1,
        price: 200,
        currency: "USD",
        investment_activity_label: "Buy"
      )
    ).trade
    @auth_headers = oauth_headers_for(@member)
  end

  test "index excludes trades from inaccessible accounts" do
    get api_v1_trades_url, headers: @auth_headers

    assert_response :success

    trade_ids = JSON.parse(response.body).fetch("trades").map { |trade| trade.fetch("id") }
    assert_includes trade_ids, @shared_trade.id
    assert_not_includes trade_ids, @private_trade.id
  end

  test "show returns not found for trade on inaccessible account" do
    get api_v1_trade_url(@private_trade), headers: @auth_headers

    assert_response :not_found
  end

  test "create rejects trades for non-writable private accounts" do
    assert_no_difference("Trade.count") do
      post api_v1_trades_url,
           params: {
             trade: {
               account_id: @private_account.id,
               date: Date.current.to_s,
               qty: 1,
               price: 200,
               type: "buy",
               security_id: @security.id
             }
           },
           headers: @auth_headers
    end

    assert_response :not_found
  end

  test "update rejects trades on readable but non-writable accounts" do
    patch api_v1_trade_url(@shared_trade),
          params: { trade: { qty: 2, price: 210, type: "buy" } },
          headers: @auth_headers

    assert_response :not_found
    assert_equal 1.to_d, @shared_trade.reload.qty
  end

  test "destroy rejects trades on readable but non-writable accounts" do
    assert_no_difference("Trade.count") do
      delete api_v1_trade_url(@shared_trade), headers: @auth_headers
    end

    assert_response :not_found
  end

  private

    def oauth_headers_for(user, scopes: "read_write")
      access_grant = Doorkeeper::AccessToken.create!(
        application: oauth_application,
        resource_owner_id: user.id,
        scopes: scopes
      )
      { "Authorization" => "Bearer #{access_grant.token}" }
    end

    def oauth_application
      @oauth_application ||= Doorkeeper::Application.create!(
        name: "Trades API Test App",
        redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
        scopes: "read read_write"
      )
    end
end
