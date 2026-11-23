require "test_helper"

class Oauth::TokensControllerTest < ActionDispatch::IntegrationTest
  REDIRECT_URI = "https://client.example.com/callback".freeze

  setup do
    @user = users(:family_member)
    @oauth_app = Doorkeeper::Application.create!(name: "Token endpoint", redirect_uri: REDIRECT_URI, scopes: "read read_write")
  end

  test "refresh issues a successor for the same user, client and scopes" do
    token = issue_token

    post_refresh token.plaintext_refresh_token

    assert_response :success
    successor = Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"])
    assert_equal @user.id, successor.resource_owner_id
    assert_equal @oauth_app.id, successor.application_id
    assert_equal "read_write", successor.scopes.to_s
    assert_not token.reload.revoked?, "the predecessor stays valid until the successor is first used"
  end

  test "refresh is refused once the user is inactive, even if their tokens were not revoked" do
    token = issue_token
    @user.update_column(:active, false)

    assert_no_difference -> { Doorkeeper::AccessToken.count } do
      post_refresh token.plaintext_refresh_token
    end

    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "refresh is refused when the token's user no longer exists" do
    token = issue_token(resource_owner_id: SecureRandom.uuid)

    assert_no_difference -> { Doorkeeper::AccessToken.count } do
      post_refresh token.plaintext_refresh_token
    end

    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "refresh is refused when the token disappears before the user lock is taken" do
    token = issue_token
    Doorkeeper::AccessToken.any_instance.stubs(:reload).raises(ActiveRecord::RecordNotFound)

    assert_no_difference -> { Doorkeeper::AccessToken.count } do
      post_refresh token.plaintext_refresh_token
    end

    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "an unknown refresh token gets Doorkeeper's own error" do
    post_refresh "not-a-refresh-token"

    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "an authorization code is exchanged for a token" do
    grant = issue_grant

    post_code grant.plaintext_token

    assert_response :success
    assert_equal @user.id, Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"]).resource_owner_id
    assert grant.reload.revoked?
  end

  test "an authorization code is refused once the user is inactive" do
    grant = issue_grant
    @user.update_column(:active, false)

    assert_no_difference -> { Doorkeeper::AccessToken.count } do
      post_code grant.plaintext_token
    end

    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "client credentials, which carry no user, are left to Doorkeeper" do
    post "/oauth/token", params: {
      grant_type: "client_credentials",
      client_id: @oauth_app.uid,
      client_secret: @oauth_app.plaintext_secret
    }

    assert_response :success
    assert_nil Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"]).resource_owner_id
  end

  private

    def issue_token(resource_owner_id: @user.id)
      Doorkeeper::AccessToken.create!( # pipelock:ignore
        application: @oauth_app,
        resource_owner_id: resource_owner_id,
        scopes: "read_write",
        expires_in: 2.hours,
        use_refresh_token: true
      )
    end

    def issue_grant
      Doorkeeper::AccessGrant.create!(
        application: @oauth_app,
        resource_owner_id: @user.id,
        redirect_uri: REDIRECT_URI,
        scopes: "read_write",
        expires_in: 10.minutes
      )
    end

    def post_refresh(refresh_token)
      post "/oauth/token", params: {
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: @oauth_app.uid,
        client_secret: @oauth_app.plaintext_secret
      }
    end

    def post_code(code)
      post "/oauth/token", params: {
        grant_type: "authorization_code",
        code: code,
        redirect_uri: REDIRECT_URI,
        client_id: @oauth_app.uid,
        client_secret: @oauth_app.plaintext_secret
      }
    end
end
