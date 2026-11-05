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

  test "update signs the user out of their other web sessions and keeps the current one" do
    current_session = @user.sessions.order(:created_at).last
    other_session = @user.sessions.create!

    patch password_path, params: {
      user: {
        password_challenge: user_password_test,
        password: "NewSecure1!pass",
        password_confirmation: "NewSecure1!pass"
      }
    }

    assert_redirected_to root_path
    assert Session.exists?(current_session.id)
    assert_not Session.exists?(other_session.id)
  end
end
