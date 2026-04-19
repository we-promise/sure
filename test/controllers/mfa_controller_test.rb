require "test_helper"

class MfaControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_member)
    sign_in @user
  end

  def sign_out
    @user.sessions.each do |session|
      delete session_path(session)
    end
  end

  test "redirects to root if MFA already enabled" do
    @user.setup_mfa!
    @user.enable_mfa!

    get new_mfa_path
    assert_redirected_to root_path
  end

  test "sets up MFA when visiting new" do
    get new_mfa_path

    assert_response :success
    assert @user.reload.otp_secret.present?
    assert_not @user.otp_required?
    assert_select "svg" # QR code should be present
  end

  test "enables MFA with valid code" do
    @user.setup_mfa!
    totp = ROTP::TOTP.new(@user.otp_secret, issuer: "Sure Finances")

    post mfa_path, params: { code: totp.now, password: user_password_test }

    assert_response :success
    assert @user.reload.otp_required?
    assert_equal 8, @user.otp_backup_codes.length
    assert_select "div.grid-cols-2" # Check for backup codes grid
  end

  test "does not enable MFA with invalid code" do
    @user.setup_mfa!

    post mfa_path, params: { code: "invalid", password: user_password_test }

    assert_redirected_to new_mfa_path
    assert_not @user.reload.otp_required?
    assert_empty @user.otp_backup_codes
  end

  test "enables MFA only with correct password" do
    @user.setup_mfa!
    totp = ROTP::TOTP.new(@user.otp_secret, issuer: "Sure Finances")

    post mfa_path, params: { code: totp.now, password: "wrongpassword" }

    @user.reload
    assert_not @user.otp_required?
    assert_redirected_to new_mfa_path
    # A wrong password during enable must NOT wipe the in-progress setup;
    # only an actual code mismatch / session expiry should do that. Prevents
    # a single typo from forcing a QR re-scan.
    assert @user.otp_secret.present?, "otp_secret should survive a wrong-password attempt"
  end

  test "SSO-only users (no password_digest) cannot enable MFA" do
    @user.setup_mfa!
    totp = ROTP::TOTP.new(@user.otp_secret, issuer: "Sure Finances")
    @user.update_column(:password_digest, nil) # simulate SSO-only user

    post mfa_path, params: { code: totp.now, password: "anything" }

    assert_not @user.reload.otp_required?
    assert_redirected_to new_mfa_path
  end

  test "SSO-only users cannot disable MFA via password" do
    @user.setup_mfa!
    @user.enable_mfa!
    @user.update_column(:password_digest, nil) # simulate SSO-only user

    delete disable_mfa_path, params: { password: "anything" }

    assert @user.reload.otp_required?
    assert_redirected_to settings_security_path
  end

  test "verify shows MFA verification page" do
    @user.setup_mfa!
    @user.enable_mfa!
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }
    assert_redirected_to verify_mfa_path

    get verify_mfa_path
    assert_response :success
    assert_select "form[action=?]", verify_mfa_path
  end

  test "verify_code authenticates with valid TOTP" do
    @user.setup_mfa!
    @user.enable_mfa!
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }
    totp = ROTP::TOTP.new(@user.otp_secret, issuer: "Sure Finances")

    post verify_mfa_path, params: { code: totp.now }

    assert_redirected_to root_path
    assert Session.exists?(user_id: @user.id)
  end

  test "verify_code authenticates with valid backup code" do
    @user.setup_mfa!
    @user.enable_mfa!
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }
    backup_code = @user.otp_backup_codes.first

    post verify_mfa_path, params: { code: backup_code }

    assert_redirected_to root_path
    assert Session.exists?(user_id: @user.id)
    assert_not @user.reload.otp_backup_codes.include?(backup_code)
  end

  test "verify_code rejects invalid codes" do
    @user.setup_mfa!
    @user.enable_mfa!
    sign_out

    post sessions_path, params: { email: @user.email, password: user_password_test }
    post verify_mfa_path, params: { code: "invalid" }

    assert_response :unprocessable_entity
    assert_not Session.exists?(user_id: @user.id)
  end

  test "disable removes MFA" do
    @user.setup_mfa!
    @user.enable_mfa!

    delete disable_mfa_path, params: { password: user_password_test }

    assert_redirected_to settings_security_path
    assert_not @user.reload.otp_required?
    assert_nil @user.otp_secret
    assert_empty @user.otp_backup_codes
  end

  test "disabling MFA requires correct password" do
    @user.setup_mfa!
    @user.enable_mfa!

    delete disable_mfa_path, params: { password: "wrongpassword" }

    assert @user.reload.otp_required?
    assert_redirected_to settings_security_path
  end
end
