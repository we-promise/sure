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
    original_digest = @user.password_digest

    patch password_path, params: { user: { password_challenge: user_password_test, password: "newtestpassword817983172", password_confirmation: "newtestpassword817983172" } }

    assert_redirected_to root_path
    assert_not_equal original_digest, @user.reload.password_digest
    assert SecurityAuditLog.exists?(user: @user, event_type: "password_changed")
  end

  test "update rejects a wrong current password" do
    assert_password_unchanged do
      patch password_path, params: { user: { password_challenge: "wrongpassword123", password: "newtestpassword817983172", password_confirmation: "newtestpassword817983172" } }
    end
  end

  test "update rejects a blank or missing current password" do
    assert_password_unchanged do
      patch password_path, params: { user: { password_challenge: "", password: "newtestpassword817983172", password_confirmation: "newtestpassword817983172" } }
    end

    assert_password_unchanged do
      patch password_path, params: { user: { password: "newtestpassword817983172", password_confirmation: "newtestpassword817983172" } }
    end
  end

  test "update rejects a mismatched confirmation" do
    assert_password_unchanged do
      patch password_path, params: { user: { password_challenge: user_password_test, password: "newtestpassword817983172", password_confirmation: "differentpassword817983172" } }
    end
  end

  test "update rejects a blank new password" do
    assert_password_unchanged do
      patch password_path, params: { user: { password_challenge: user_password_test, password: "", password_confirmation: "" } }
    end
  end

  test "update with a too short password does not write an audit log" do
    assert_password_unchanged do
      patch password_path, params: { user: { password_challenge: user_password_test, password: "short", password_confirmation: "short" } }
    end
  end

  test "rolls back the password change when the audit log write fails" do
    SecurityAuditLog.stubs(:log_password_changed!).raises(ActiveRecord::RecordInvalid.new(SecurityAuditLog.new))
    original_digest = @user.password_digest

    patch password_path, params: { user: { password_challenge: user_password_test, password: "newtestpassword817983172", password_confirmation: "newtestpassword817983172" } }

    assert_response :unprocessable_entity
    assert_equal original_digest, @user.reload.password_digest
  end

  private

    def assert_password_unchanged
      original_digest = @user.reload.password_digest

      assert_no_difference "SecurityAuditLog.count" do
        yield
      end

      assert_response :unprocessable_entity
      assert_equal original_digest, @user.reload.password_digest
    end
end
