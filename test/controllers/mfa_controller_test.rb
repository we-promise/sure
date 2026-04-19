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

    post mfa_path, params: { code: totp.now }

    assert_response :success
    assert @user.reload.otp_required?
    assert_equal 8, @user.otp_backup_codes.length
    assert_select "div.grid-cols-2" # Check for backup codes grid
  end

  test "does not enable MFA with invalid code" do
    @user.setup_mfa!

    post mfa_path, params: { code: "invalid" }

    assert_redirected_to new_mfa_path
    assert_not @user.reload.otp_required?
    assert_empty @user.otp_backup_codes
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

    delete disable_mfa_path

    assert_redirected_to settings_security_path
    assert_not @user.reload.otp_required?
    assert_nil @user.otp_secret
    assert_empty @user.otp_backup_codes
  end

  # ── Security tests added with pentest fixes (PT-003) ─────────────────────────

  test "MFA verify_code rate-limits after 5 attempts" do
    other_user = users(:family_admin)
    other_user.setup_mfa!
    other_user.enable_mfa!

    sign_out
    # Simulate partial login with MFA pending
    post sessions_path, params: { email: other_user.email, password: user_password_test }

    6.times do
      post verify_mfa_path, params: { code: "000000" }
    end

    assert_redirected_to new_session_path
  end

  test "MFA session expires after TTL" do
    other_user = users(:family_admin)
    other_user.setup_mfa!
    other_user.enable_mfa!

    sign_out
    post sessions_path, params: { email: other_user.email, password: user_password_test }

    # Travel past the 5 minute TTL window
    travel_to(6.minutes.from_now) do
      # Capture how many sessions the user had before the MFA attempt so we
      # can assert no new one was created. Any existing session from sign-in
      # below is from the sign_out/post cycle above (which creates an MFA
      # handoff but no auth session yet).
      before = Session.where(user_id: other_user.id).count

      post verify_mfa_path, params: { code: ROTP::TOTP.new(other_user.otp_secret).now }

      assert_redirected_to new_session_path
      # Negative assertion: the TTL branch cleared the MFA handoff and the OTP
      # was NOT accepted as a legitimate login.
      assert_nil session[:mfa_user_id], "MFA handoff should be cleared on TTL expiry"
      assert_equal before, Session.where(user_id: other_user.id).count,
        "No auth session should be created when MFA expires"
    end
  end
end
