require "test_helper"

class PasswordResetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
  end

  test "new" do
    get new_password_reset_path
    assert_response :ok
  end

  test "create" do
    assert_enqueued_emails 1 do
      post password_reset_path, params: { email: @user.email }
      assert_redirected_to new_password_reset_url(step: "pending")
    end
  end

  test "edit" do
    get edit_password_reset_path(token: @user.generate_token_for(:password_reset))
    assert_response :ok
  end

  test "update" do
    patch password_reset_path(token: @user.generate_token_for(:password_reset)),
      params: { user: { password: "password", password_confirmation: "password" } }
    assert_redirected_to new_session_url

    assert SecurityAuditLog.exists?(user: @user, event_type: "password_changed")
  end

  test "update with an invalid password does not write an audit log" do
    # has_secure_password validations: false (see app/models/user.rb) means
    # password_confirmation mismatches aren't actually validated — only the
    # minimum-length rule is, so that's the real failure mode to exercise.
    assert_no_difference "SecurityAuditLog.count" do
      patch password_reset_path(token: @user.generate_token_for(:password_reset)),
        params: { user: { password: "short", password_confirmation: "short" } }
    end
    assert_response :unprocessable_entity
  end

  test "rolls back the password change when the audit log write fails" do
    SecurityAuditLog.stubs(:log_password_changed!).raises(ActiveRecord::RecordInvalid.new(SecurityAuditLog.new))
    original_digest = @user.password_digest

    patch password_reset_path(token: @user.generate_token_for(:password_reset)),
      params: { user: { password: "password", password_confirmation: "password" } }

    assert_response :unprocessable_entity
    assert_equal original_digest, @user.reload.password_digest
  end

  test "all actions redirect when password features are disabled" do
    AuthConfig.stubs(:password_features_enabled?).returns(false)

    get new_password_reset_path
    assert_redirected_to new_session_path
    assert_equal "Password reset via Sure is disabled. Please reset your password through your identity provider.", flash[:alert]

    post password_reset_path, params: { email: @user.email }
    assert_redirected_to new_session_path
    assert_equal "Password reset via Sure is disabled. Please reset your password through your identity provider.", flash[:alert]

    get edit_password_reset_path(token: @user.generate_token_for(:password_reset))
    assert_redirected_to new_session_path
    assert_equal "Password reset via Sure is disabled. Please reset your password through your identity provider.", flash[:alert]

    patch password_reset_path(token: @user.generate_token_for(:password_reset)),
      params: { user: { password: "password", password_confirmation: "password" } }
    assert_redirected_to new_session_path
    assert_equal "Password reset via Sure is disabled. Please reset your password through your identity provider.", flash[:alert]
  end

  # Security: SSO-only users should not receive password reset emails
  test "create does not send email for SSO-only user" do
    sso_user = users(:sso_only)
    assert sso_user.sso_only?, "Test user should be SSO-only"

    assert_no_enqueued_emails do
      post password_reset_path, params: { email: sso_user.email }
    end

    # Should still redirect to pending to prevent email enumeration
    assert_redirected_to new_password_reset_url(step: "pending")
  end

  test "create sends email for user with local password" do
    assert @user.has_local_password?, "Test user should have local password"

    assert_enqueued_emails 1 do
      post password_reset_path, params: { email: @user.email }
    end

    assert_redirected_to new_password_reset_url(step: "pending")
  end

  # Security: SSO-only users cannot set password via reset
  test "update blocks password setting for SSO-only user" do
    sso_user = users(:sso_only)
    token = sso_user.generate_token_for(:password_reset)

    patch password_reset_path(token: token),
      params: { user: { password: "NewSecure1!", password_confirmation: "NewSecure1!" } }

    assert_redirected_to new_session_path
    assert_equal "Your account uses SSO for authentication. Please contact your administrator to manage your credentials.", flash[:alert]

    # Verify password was not set
    sso_user.reload
    assert_nil sso_user.password_digest, "SSO-only user should still have nil password_digest"
  end
end
