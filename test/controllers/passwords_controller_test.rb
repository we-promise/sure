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

  test "update changes the password when it meets the sign-up rules and writes an audit log" do
    patch password_path, params: { user: {
      password_challenge: user_password_test,
      password: "NewSecure1!",
      password_confirmation: "NewSecure1!"
    } }

    assert_redirected_to root_url
    assert @user.reload.authenticate("NewSecure1!")
    assert SecurityAuditLog.exists?(user: @user, event_type: "password_changed")
  end

  test "update rejects a wrong current password" do
    assert_password_unchanged do
      patch password_path, params: { user: {
        password_challenge: "WrongPassword1!",
        password: "NewSecure1!",
        password_confirmation: "NewSecure1!"
      } }
    end

    assert_select "p.text-destructive", text: /Current Password is invalid/
  end

  test "update rejects a blank or missing current password" do
    [ { password_challenge: "" }, {} ].each do |challenge|
      assert_password_unchanged do
        patch password_path, params: { user: challenge.merge(password: "NewSecure1!", password_confirmation: "NewSecure1!") }
      end
    end
  end

  test "update rejects a current password sent as null" do
    assert_password_unchanged do
      patch password_path, params: { user: {
        password_challenge: nil,
        password: "NewSecure1!",
        password_confirmation: "NewSecure1!"
      } }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    end
  end

  test "update rejects a current password field sent without a value" do
    assert_password_unchanged do
      patch password_path, params: "user[password_challenge]&user[password]=NewSecure1!&user[password_confirmation]=NewSecure1!",
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    end
  end

  test "update does not let a user without a local password set one here" do
    @user.update_column(:password_digest, nil)

    assert_no_difference "SecurityAuditLog.count" do
      patch password_path, params: { user: {
        password_challenge: "",
        password: "NewSecure1!",
        password_confirmation: "NewSecure1!"
      } }
    end

    assert_response :unprocessable_entity
    assert_nil @user.reload.password_digest
  end

  test "update rejects a mismatched confirmation" do
    assert_password_unchanged do
      patch password_path, params: { user: {
        password_challenge: user_password_test,
        password: "NewSecure1!",
        password_confirmation: "Different1!"
      } }
    end

    assert_select "p.text-destructive", text: /doesn't match Password/
  end

  test "update rejects a password that only meets the minimum length" do
    assert_password_unchanged do
      patch password_path, params: { user: {
        password_challenge: user_password_test,
        password: "password",
        password_confirmation: "password"
      } }
    end

    assert_select "p.text-destructive", text: /uppercase and lowercase/
  end

  test "update names each missing character type" do
    assert_password_unchanged do
      patch password_path, params: { user: {
        password_challenge: user_password_test,
        password: "Abcdefgh",
        password_confirmation: "Abcdefgh"
      } }
    end

    assert_select "p.text-destructive", text: /at least one number/
    assert_select "p.text-destructive", text: /at least one special character/
  end

  test "update rejects a too short password" do
    assert_password_unchanged do
      patch password_path, params: { user: { password_challenge: user_password_test, password: "Sh1!", password_confirmation: "Sh1!" } }
    end
  end

  test "update rejects a password longer than 72 bytes" do
    too_long = "Aa1!" + "ü" * 35

    assert_password_unchanged do
      patch password_path, params: { user: {
        password_challenge: user_password_test,
        password: too_long,
        password_confirmation: too_long
      } }
    end

    assert_select "p.text-destructive", text: /maximum is 72 bytes/
  end

  test "update rejects a blank new password instead of reporting success" do
    assert_password_unchanged do
      patch password_path, params: { user: {
        password_challenge: user_password_test,
        password: "",
        password_confirmation: ""
      } }
    end

    assert_select "p.text-destructive", text: /can't be blank/
  end

  test "rolls back the password change when the audit log write fails" do
    SecurityAuditLog.stubs(:log_password_changed!).raises(ActiveRecord::RecordInvalid.new(SecurityAuditLog.new))
    original_digest = @user.password_digest

    patch password_path, params: { user: { password_challenge: user_password_test, password: "NewSecure1!", password_confirmation: "NewSecure1!" } }

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
