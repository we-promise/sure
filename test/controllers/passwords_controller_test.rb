require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "edit" do
    get edit_password_path
    assert_response :ok
  end

  test "update changes the password and writes an audit log" do
    patch password_path, params: { user: { password: "newtestpassword817983172", password_confirmation: "newtestpassword817983172" } }

    assert_redirected_to root_path
    assert SecurityAuditLog.exists?(user: @user, event_type: "password_changed")
  end

  test "update with an invalid password does not write an audit log" do
    # has_secure_password validations: false (see app/models/user.rb) means
    # password_confirmation mismatches aren't actually validated — only the
    # minimum-length rule is, so that's the real failure mode to exercise.
    assert_no_difference "SecurityAuditLog.count" do
      patch password_path, params: { user: { password: "short", password_confirmation: "short" } }
    end
    assert_response :unprocessable_entity
  end

  test "rolls back the password change when the audit log write fails" do
    SecurityAuditLog.stubs(:log_password_changed!).raises(ActiveRecord::RecordInvalid.new(SecurityAuditLog.new))
    original_digest = @user.password_digest

    patch password_path, params: { user: { password: "newtestpassword817983172", password_confirmation: "newtestpassword817983172" } }

    assert_response :unprocessable_entity
    assert_equal original_digest, @user.reload.password_digest
  end
end
