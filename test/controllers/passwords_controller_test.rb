require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "update revokes the user's OAuth access tokens" do
    app = Doorkeeper::Application.create!(
      name: "Test App #{SecureRandom.hex(4)}",
      redirect_uri: "https://example.com/callback",
      confidential: false
    )
    token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: app,
      resource_owner_id: @user.id,
      scopes: "read_write",
      expires_in: 1.year
    )

    patch password_path, params: {
      user: {
        password_challenge: user_password_test,
        password: "NewSecure1!pass",
        password_confirmation: "NewSecure1!pass"
      }
    }

    assert_redirected_to root_path
    assert token.reload.revoked_at.present?
  end
end
