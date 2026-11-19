require "test_helper"

class EmailConfirmationsControllerTest < ActionDispatch::IntegrationTest
  test "should get confirm" do
    user = users(:new_email)
    user.update!(unconfirmed_email: "new@example.com")
    token = user.generate_token_for(:email_confirmation)

    get new_email_confirmation_path(token: token)
    assert_redirected_to new_session_path
    assert user.reload.email_verified?
  end

  test "verifies the current email for a new account" do
    user = users(:family_member)
    user.update!(email_verified_at: nil)
    token = user.generate_token_for(:email_confirmation)

    get new_email_confirmation_path(token: token)

    assert_redirected_to new_session_path
    assert user.reload.email_verified?
  end
end
