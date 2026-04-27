class MfaController < ApplicationController
  layout :determine_layout
  skip_authentication only: [ :verify, :verify_code ]
  before_action :block_sso_only_users, only: [ :new, :create, :disable ]

  def new
    redirect_to root_path if Current.user.otp_required?
    Current.user.setup_mfa! unless Current.user.otp_secret.present?
  end

  def create
    unless password_reauth_ok?
      # Do NOT call disable_mfa! here — a wrong password during enable should
      # not wipe the in-progress otp_secret / backup codes. Only an actual
      # code mismatch below invalidates the setup.
      redirect_to new_mfa_path, alert: t(".invalid_password")
      return
    end

    if Current.user.verify_otp?(params[:code])
      Current.user.enable_mfa!
      @backup_codes = Current.user.otp_backup_codes
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

    if @user&.verify_otp?(params[:code])
      session.delete(:mfa_user_id)
      @session = create_session_for(@user)
      flash[:notice] = t("invitations.accept_choice.joined_household") if accept_pending_invitation_for(@user)
      redirect_to root_path
    else
      flash.now[:alert] = t(".invalid_code")
      render :verify, status: :unprocessable_entity
    end
  end

  def disable
    unless password_reauth_ok?
      redirect_to settings_security_path, alert: t(".invalid_password")
      return
    end

    Current.user.disable_mfa!
    redirect_to settings_security_path, notice: t(".success")
  end

  private

    # SSO-only users can't satisfy the password prompt MFA enable/disable
    # requires (F-11). Block every MFA management action for them — including
    # GET /mfa/new, which would otherwise call setup_mfa! and leave an
    # incomplete otp_secret the user can never finish wiring up. The view
    # already hides the enable/disable UI for these users; this is the
    # server-side backstop for a direct-URL visit.
    def block_sso_only_users
      return if Current.user.password_digest.present?
      redirect_to settings_security_path, alert: t("mfa.new.sso_only_not_supported", default: "Two-factor authentication requires a local password — it is managed through your identity provider.")
    end

    # Password re-auth for sensitive MFA operations. SSO-only users are
    # already rejected by block_sso_only_users, but the guard here is kept
    # for defense-in-depth.
    def password_reauth_ok?
      return false if Current.user.password_digest.blank?
      Current.user.authenticate(params[:password]).present?
    end

    def determine_layout
      if action_name.in?(%w[verify verify_code])
        "auth"
      else
        "settings"
      end
    end
end
