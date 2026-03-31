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
    @auth_headers = oauth_headers_for(@member)
  end

  test "index excludes holdings from inaccessible accounts" do
    get api_v1_holdings_url, headers: @auth_headers

    assert_response :success

    holding_ids = JSON.parse(response.body).fetch("holdings").map { |holding| holding.fetch("id") }
    assert_includes holding_ids, @shared_holding.id
    assert_not_includes holding_ids, @private_holding.id
  end

  test "show returns not found for holding on inaccessible account" do
    get api_v1_holding_url(@private_holding), headers: @auth_headers

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
        name: "Holdings API Test App",
        redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
        scopes: "read read_write"
      )
    end
end
