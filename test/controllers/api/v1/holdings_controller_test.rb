# frozen_string_literal: true

require "test_helper"

class Api::V1::HoldingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @member = users(:family_member)
    @private_holding = holdings(:one)
    @shared_holding = Holding.create!(
      account: accounts(:depository),
      security: securities(:aapl),
      date: Date.current,
      qty: 2,
      price: 200,
      amount: 400,
      currency: "USD"
    )

    @oauth_app = Doorkeeper::Application.create!(
      name: "Holdings API Test App",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scopes: "read read_write"
    )
    @token = access_token_for(@member)
  end

  test "index excludes holdings from inaccessible accounts" do
    get api_v1_holdings_url, headers: bearer_headers(@token)

    assert_response :success

    holding_ids = JSON.parse(response.body).fetch("holdings").map { |holding| holding.fetch("id") }
    assert_includes holding_ids, @shared_holding.id
    assert_not_includes holding_ids, @private_holding.id
  end

  test "show returns not found for holding on inaccessible account" do
    get api_v1_holding_url(@private_holding), headers: bearer_headers(@token)

    assert_response :not_found
  end

  private

    def access_token_for(user, scopes: "read_write")
      Doorkeeper::AccessToken.create!(
        application: @oauth_app,
        resource_owner_id: user.id,
        scopes: scopes
      ).token
    end

    def bearer_headers(token)
      { "Authorization" => "Bearer #{token}" }
    end
end
