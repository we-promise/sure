class MfaController < ApplicationController
  layout :determine_layout
  skip_authentication only: [ :verify, :verify_code ]

  def new
    redirect_to root_path if Current.user.otp_required?
    Current.user.setup_mfa! unless Current.user.otp_secret.present?
  end

  def create
    unless Current.user.authenticate(params[:password])
      Current.user.disable_mfa!
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

    # Rate limit: max 5 attempts, then force re-login
    session[:mfa_attempts] = (session[:mfa_attempts] || 0) + 1
    if session[:mfa_attempts] > 5
      session.delete(:mfa_user_id)
      session.delete(:mfa_attempts)
      redirect_to new_session_path, alert: t(".too_many_attempts", default: "Too many attempts. Please sign in again.")
      return
    end

    # TTL: MFA flow expires after 5 minutes
    if session[:mfa_started_at].present? && Time.current - Time.parse(session[:mfa_started_at].to_s) > 5.minutes
      session.delete(:mfa_user_id)
      session.delete(:mfa_attempts)
      session.delete(:mfa_started_at)
      redirect_to new_session_path, alert: t(".session_expired", default: "MFA session expired. Please sign in again.")
      return
    end

    if @user&.verify_otp?(params[:code])
      session.delete(:mfa_user_id)
      session.delete(:mfa_attempts)
      session.delete(:mfa_started_at)
      reset_session  # Prevent session fixation
      @session = create_session_for(@user)
      flash[:notice] = t("invitations.accept_choice.joined_household") if accept_pending_invitation_for(@user)
      redirect_to root_path
    else
      flash.now[:alert] = t(".invalid_code")
      render :verify, status: :unprocessable_entity
    end
  end

  def disable
    unless Current.user.authenticate(params[:password])
      redirect_to settings_security_path, alert: t(".invalid_password")
      return
    end
    Current.user.disable_mfa!
    redirect_to settings_security_path, notice: t(".success")
  end

  private

    def determine_layout
      if action_name.in?(%w[verify verify_code])
        "auth"
      else
        "settings"
      end
    end
end
