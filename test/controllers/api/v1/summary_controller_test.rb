# frozen_string_literal: true

require "test_helper"

class Api::V1::SummaryControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read read_write"
    )
  end

  test "should require authentication" do
    get "/api/v1/summary"
    assert_response :unauthorized
  end

  test "should return summary with net worth data" do
    access_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    get "/api/v1/summary", headers: {
      "Authorization" => "Bearer #{access_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    assert response_body.key?("currency")
    assert response_body.key?("net_worth")
    assert response_body.key?("assets")
    assert response_body.key?("liabilities")

    # Net worth should have amount, currency, formatted fields
    %w[net_worth assets liabilities].each do |field|
      assert response_body[field].key?("amount"), "#{field} should have amount"
      assert response_body[field].key?("currency"), "#{field} should have currency"
      assert response_body[field].key?("formatted"), "#{field} should have formatted"
    end
  end

  test "should work with API key authentication" do
    @user.api_keys.active.destroy_all
    api_key = ApiKey.create!(
      user: @user,
      name: "Test Key",
      scopes: [ "read" ],
      display_key: "summary_test_#{SecureRandom.hex(8)}"
    )

    get "/api/v1/summary", headers: { "X-Api-Key" => api_key.display_key }

    assert_response :success
    response_body = JSON.parse(response.body)
    assert response_body.key?("net_worth")

    Redis.new.del("api_rate_limit:#{api_key.id}")
  end
end
