class MfaController < ApplicationController
  include WebauthnRelyingParty

  layout :determine_layout
  skip_authentication only: [ :verify, :verify_code, :webauthn_options, :verify_webauthn ]
  before_action :require_local_password, only: [ :new, :create, :disable ]

  def new
    redirect_to root_path if Current.user.otp_required?
    Current.user.setup_mfa! unless Current.user.otp_secret.present?
  end

  def create
    unless password_confirmed?
      # Deliberately not disable_mfa! here: a wrong password must not throw away
      # the otp_secret and backup codes the user is midway through setting up.
      # Only a code mismatch below does that.
      redirect_to new_mfa_path, alert: t(".invalid_password")
      return
    end

    if Current.user.verify_otp?(params[:code])
      @backup_codes = Current.user.enable_mfa!
      render :backup_codes
    else
      Current.user.disable_mfa!
      redirect_to new_mfa_path, alert: t(".invalid_code")
    end
  end

  def verify
    @user = User.find_by(id: session[:mfa_user_id])

    if @user.nil?
      redirect_to new_session_path
    end
  end

  def verify_code
    @user = User.find_by(id: session[:mfa_user_id])

    # Check before verify_otp? — a backup code is single-use and gets consumed
    # by verification, so a deactivated user shouldn't be able to burn one on
    # a login attempt that was always going to be rejected.
    if @user && !@user.active?
      session.delete(:mfa_user_id)
      redirect_to new_session_path, alert: t("sessions.create.account_deactivated")
    elsif @user&.verify_otp?(params[:code])
      if complete_mfa_sign_in(@user)
        redirect_to root_path
      else
        redirect_to new_session_path, alert: t("sessions.create.account_deactivated")
      end
    else
      flash.now[:alert] = t(".invalid_code")
      render :verify, status: :unprocessable_entity
    end
  end

  def webauthn_options
    @user = User.find_by(id: session[:mfa_user_id])

    unless @user&.webauthn_enabled?
      return render json: { error: t(".unavailable") }, status: :unprocessable_entity
    end

    options = webauthn_relying_party.options_for_authentication(
      allow: @user.webauthn_credentials.pluck(:credential_id),
      user_verification: "preferred"
    )
    session[:webauthn_authentication_challenge] = options.challenge

    render json: options
  end

  def verify_webauthn
    @user = User.find_by(id: session[:mfa_user_id])
    challenge = session.delete(:webauthn_authentication_challenge)

    unless @user&.webauthn_enabled? && challenge.present?
      return render json: { error: t(".invalid_credential") }, status: :unprocessable_entity
    end

    # Check before verifying/consuming the credential (sign_count gets
    # bumped below) — a deactivated user shouldn't be able to spend a
    # WebAuthn assertion on a login that was always going to be rejected.
    unless @user.active?
      session.delete(:mfa_user_id)
      return render json: { error: t("sessions.create.account_deactivated") }, status: :unauthorized
    end

    credential = WebAuthn::Credential.from_get(
      webauthn_credential_payload,
      relying_party: webauthn_relying_party
    )
    stored_credential = @user.webauthn_credentials.find_by(credential_id: credential.id)

    unless stored_credential
      return render json: { error: t(".invalid_credential") }, status: :unprocessable_entity
    end

    stored_credential.with_lock do
      credential.verify(
        challenge,
        public_key: stored_credential.public_key,
        sign_count: stored_credential.sign_count,
        user_presence: true
      )

      stored_credential.update!(
        sign_count: credential.sign_count,
        last_used_at: Time.current
      )
    end
    unless complete_mfa_sign_in(@user)
      return render json: { error: t(".invalid_credential") }, status: :unprocessable_entity
    end

    render json: { redirect_url: root_path }
  rescue WebAuthn::Error, ActionController::BadRequest, ActionController::ParameterMissing
    render json: { error: t(".invalid_credential") }, status: :unprocessable_entity
  end

  def disable
    unless password_confirmed?
      redirect_to settings_security_path, alert: t(".invalid_password")
      return
    end

    Current.user.disable_mfa!
    redirect_to settings_security_path, notice: t(".success")
  end

  private

    # Turning the second factor on or off changes how the account is protected,
    # so it is confirmed with the password rather than with possession of an
    # already-open session.
    def password_confirmed?
      Current.user.authenticate(params[:password]).present?
    end

    # A user who signs in through an identity provider has no local password to
    # confirm with, so these pages are closed to them rather than left as a
    # dead end. GET /mfa/new matters as much as the writes: it calls setup_mfa!
    # and would strand an otp_secret they could never finish wiring up.
    def require_local_password
      return if Current.user.has_local_password?

      redirect_to settings_security_path, alert: t("mfa.local_password_required")
    end

    def determine_layout
      if action_name.in?(%w[webauthn_options verify_webauthn])
        false
      elsif action_name.in?(%w[verify verify_code])
        "auth"
      else
        "settings"
      end
    end

    def complete_mfa_sign_in(user)
      session.delete(:mfa_user_id)
      @session = create_session_for(user)
      return false unless @session

      flash[:notice] = t("invitations.accept_choice.joined_household") if accept_pending_invitation_for(user)
      true
    end
end
