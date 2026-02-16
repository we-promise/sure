require "test_helper"

class Api::V1::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(ai_enabled: false)

    @shared_app = Doorkeeper::Application.find_or_create_by!(name: "Sure Mobile") do |app|
      app.redirect_uri = "sureapp://oauth/callback"
      app.scopes = "read_write"
      app.confidential = false
    end

    @token = Doorkeeper::AccessToken.create!(
      application: @shared_app,
      resource_owner_id: @user.id,
      scopes: "read_write"
    )
  end

  test "should enable ai for authenticated user" do
    patch "/api/v1/user/enable_ai", headers: {
      "Authorization" => "Bearer #{@token.token}",
      "Content-Type" => "application/json"
    }

    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal true, response_data.dig("user", "ai_enabled")
    assert_equal @user.ui_layout, response_data.dig("user", "ui_layout")
    assert @user.reload.ai_enabled?
  end

  test "should require authentication when enabling ai" do
    patch "/api/v1/user/enable_ai", headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end
end
