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
    delete "/api/v1/users/me", headers: bearer_auth_header(@write_token)
    assert_response :ok

    body = JSON.parse(response.body)
    assert_equal "Account has been deleted", body["message"]

    @user.reload
    assert_not @user.active?
    assert_not_equal "bob@bobdylan.com", @user.email
  end

  test "destroy returns 422 when deactivation fails" do
    User.any_instance.stubs(:deactivate).returns(false)
    User.any_instance.stubs(:errors).returns(
      OpenStruct.new(full_messages: [ "Cannot deactivate admin with other users" ])
    )

    delete "/api/v1/users/me", headers: bearer_auth_header(@write_token)
    assert_response :unprocessable_entity

    body = JSON.parse(response.body)
    assert_equal "Failed to delete account", body["error"]
  end

  # -- API key auth ----------------------------------------------------------

  test "reset works with API key authentication" do
    @user.api_keys.destroy_all

    plain_key = ApiKey.generate_secure_key
    api_key = @user.api_keys.build(
      name: "Test API Key",
      scopes: [ "read_write" ]
    )
    api_key.key = plain_key
    api_key.save!

    assert_enqueued_with(job: FamilyResetJob) do
      delete "/api/v1/users/reset", headers: { "X-Api-Key" => plain_key }
    end

    assert_response :ok
  end

  private

    def bearer_auth_header(token)
      { "Authorization" => "Bearer #{token.token}" }
    end
end
