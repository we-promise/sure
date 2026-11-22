require "test_helper"

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other_session = @user.sessions.create!
    sign_in @user
    @current_session = Current.session
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

  test "changing the password revokes every other session and keeps the current one" do
    patch password_path, params: { user: { password_challenge: user_password_test, password: "newtestpassword817983172", password_confirmation: "newtestpassword817983172" } }

    assert_redirected_to root_path
    assert_not Session.exists?(@other_session.id)
    assert Session.exists?(@current_session.id)
  end

  test "changing the password revokes the user's OAuth access tokens" do
    oauth_app = Doorkeeper::Application.create!(name: "Sure Mobile", redirect_uri: "https://client.example.com/callback", scopes: "read_write")
    access_token = Doorkeeper::AccessToken.create!(application: oauth_app, resource_owner_id: @user.id, expires_in: 2.hours, scopes: "read_write", use_refresh_token: true)

    patch password_path, params: { user: { password_challenge: user_password_test, password: "newtestpassword817983172", password_confirmation: "newtestpassword817983172" } }

    assert_redirected_to root_path
    assert access_token.reload.revoked?, "a mobile or OAuth token must not outlive a password change"
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

  test "update rejects a null current password sent as JSON" do
    assert_password_unchanged do
      patch password_path,
        params: { user: { password_challenge: nil, password: "newtestpassword817983172", password_confirmation: "newtestpassword817983172" } }.to_json,
        headers: { "CONTENT_TYPE" => "application/json" }
    end
  end

  test "update rejects a current password key sent without a value" do
    assert_password_unchanged do
      patch password_path,
        params: "user[password_challenge]&user[password]=newtestpassword817983172&user[password_confirmation]=newtestpassword817983172",
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
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
    assert Session.exists?(@other_session.id), "a rolled-back change must not revoke sessions"
  end

  private

    def assert_password_unchanged
      original_digest = @user.reload.password_digest

      assert_no_difference "SecurityAuditLog.count" do
        yield
      end

      assert_response :unprocessable_entity
      assert_equal original_digest, @user.reload.password_digest
      assert Session.exists?(@other_session.id), "a rejected change must not revoke sessions"
    end
end
