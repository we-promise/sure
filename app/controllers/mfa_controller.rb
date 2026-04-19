class MfaController < ApplicationController
  layout :determine_layout
  skip_authentication only: [ :verify, :verify_code ]

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

    # Password re-auth for sensitive MFA operations. SSO-only users (no local
    # password) cannot satisfy a password prompt, so we treat their request as
    # a failed re-auth here and rely on the view to hide the UI / SSO re-auth
    # flow to surface a meaningful next step (app/views/settings/securities
    # already gates the MFA block on `password_digest.present?`).
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
