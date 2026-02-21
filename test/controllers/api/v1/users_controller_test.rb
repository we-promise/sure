# frozen_string_literal: true

require "test_helper"

class Api::V1::UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)

    @oauth_app = Doorkeeper::Application.create!(
      name: "Test API App",
      redirect_uri: "https://example.com/callback",
      scopes: "read write read_write"
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

  # -- Authentication --------------------------------------------------------

  test "reset requires authentication" do
    delete "/api/v1/users/reset"
    assert_response :unauthorized
  end

  test "destroy requires authentication" do
    delete "/api/v1/users/me"
    assert_response :unauthorized
  end

  # -- Scope enforcement -----------------------------------------------------

  test "reset requires write scope" do
    delete "/api/v1/users/reset", headers: bearer_auth_header(@read_token)
    assert_response :forbidden
  end

  test "destroy requires write scope" do
    delete "/api/v1/users/me", headers: bearer_auth_header(@read_token)
    assert_response :forbidden
  end

  # -- Reset -----------------------------------------------------------------

  test "reset enqueues FamilyResetJob and returns 200" do
    assert_enqueued_with(job: FamilyResetJob) do
      delete "/api/v1/users/reset", headers: bearer_auth_header(@write_token)
    end

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "Account reset has been initiated", body["message"]
  end

  # -- Delete account --------------------------------------------------------

  test "destroy deactivates user and returns 200" do
    solo_family = Family.create!(name: "Solo Family", currency: "USD", locale: "en", date_format: "%m-%d-%Y")
    solo_user = solo_family.users.create!(
      email: "solo@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: :admin
    )
    solo_token = Doorkeeper::AccessToken.create!(
      application: @oauth_app,
      resource_owner_id: solo_user.id,
      scopes: "read_write"
    )

    delete "/api/v1/users/me", headers: bearer_auth_header(solo_token)
    assert_response :ok

    body = JSON.parse(response.body)
    assert_equal "Account has been deleted", body["message"]

    solo_user.reload
    assert_not solo_user.active?
    assert_not_equal "solo@example.com", solo_user.email
  end

  test "destroy returns 422 when admin has other family members" do
    delete "/api/v1/users/me", headers: bearer_auth_header(@write_token)
    assert_response :unprocessable_entity

    body = JSON.parse(response.body)
    assert_equal "Failed to delete account", body["error"]
  end

  # -- Deactivated user ------------------------------------------------------

  test "OAuth rejects deactivated user with 401" do
    @user.update_column(:active, false)

    delete "/api/v1/users/reset", headers: bearer_auth_header(@write_token)
    assert_response :unauthorized

    body = JSON.parse(response.body)
    assert_equal "Account has been deactivated", body["message"]
  end

  test "API key rejects deactivated user with 401" do
    @user.update_column(:active, false)
    @user.api_keys.active.destroy_all

    api_key = ApiKey.create!(
      user: @user,
      name: "Test Key",
      scopes: [ "read_write" ],
      display_key: "test_deactivated_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    delete "/api/v1/users/reset", headers: api_headers(api_key)
    assert_response :unauthorized

    body = JSON.parse(response.body)
    assert_equal "Account has been deactivated", body["message"]
  end

  # -- API key auth ----------------------------------------------------------

  test "reset works with API key authentication" do
    @user.api_keys.active.destroy_all

    api_key = ApiKey.create!(
      user: @user,
      name: "Test API Key",
      scopes: [ "read_write" ],
      display_key: "test_reset_#{SecureRandom.hex(8)}"
    )

    assert_enqueued_with(job: FamilyResetJob) do
      delete "/api/v1/users/reset", headers: api_headers(api_key)
    end

    assert_response :ok
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end

    def bearer_auth_header(token)
      { "Authorization" => "Bearer #{token.token}" }
    end
end
