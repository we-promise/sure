# frozen_string_literal: true

require "test_helper"

class Api::V1::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read read_write"
    )

    @read_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read"
    )

    @write_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )
  end

  test "should require authentication" do
    get "/api/v1/user"
    assert_response :unauthorized
  end

  test "should return user and family settings" do
    get "/api/v1/user", headers: {
      "Authorization" => "Bearer #{@read_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    assert response_body.key?("user")
    assert response_body.key?("family")

    assert_equal @user.id, response_body["user"]["id"]
    assert_equal @user.email, response_body["user"]["email"]
    assert_equal @user.default_period, response_body["user"]["default_period"]

    assert_equal @family.id, response_body["family"]["id"]
    assert_equal @family.currency, response_body["family"]["currency"]
    assert_equal @family.month_start_day, response_body["family"]["month_start_day"]
  end

  test "should require write scope for update" do
    patch "/api/v1/user", params: {
      family_attributes: { month_start_day: 15 }
    }, headers: {
      "Authorization" => "Bearer #{@read_token.token}"
    }

    assert_response :forbidden
  end

  test "should update user settings with write scope" do
    patch "/api/v1/user", params: {
      default_period: "last_30_days"
    }, headers: {
      "Authorization" => "Bearer #{@write_token.token}"
    }

    assert_response :success
    @user.reload
    assert_equal "last_30_days", @user.default_period
  end

  test "should update family month_start_day with write scope" do
    patch "/api/v1/user", params: {
      family_attributes: { month_start_day: 15 }
    }, headers: {
      "Authorization" => "Bearer #{@write_token.token}"
    }

    assert_response :success
    @family.reload
    assert_equal 15, @family.month_start_day
  end

  test "should return updated settings after update" do
    patch "/api/v1/user", params: {
      family_attributes: { month_start_day: 25 }
    }, headers: {
      "Authorization" => "Bearer #{@write_token.token}"
    }

    assert_response :success
    response_body = JSON.parse(response.body)

    assert_equal 25, response_body["family"]["month_start_day"]
  end
end
