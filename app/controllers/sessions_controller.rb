class SessionsController < ApplicationController
  before_action :set_session, only: :destroy
  skip_authentication only: %i[new create openid_connect failure]

  layout "auth"

  def new
    begin
      demo = Rails.application.config_for(:demo)
      @prefill_demo_credentials = demo_host_match?(demo)
      if @prefill_demo_credentials
        @email = params[:email].presence || demo["email"]
        @password = params[:password].presence || demo["password"]
      else
        @email = params[:email]
        @password = params[:password]
      end
    rescue RuntimeError, Errno::ENOENT, Psych::SyntaxError
      # Demo config file missing or malformed - disable demo credential prefilling
      @prefill_demo_credentials = false
      @email = params[:email]
      @password = params[:password]
    end
  end

  def create
    user = nil

    if AuthConfig.local_login_enabled?
      user = User.authenticate_by(email: params[:email], password: params[:password])
    else
      # Local login is disabled. Only allow attempts when an emergency super-admin
      # override is enabled and the email belongs to a super-admin.
      if AuthConfig.local_admin_override_enabled?
        candidate = User.find_by(email: params[:email])
        unless candidate&.super_admin?
          redirect_to new_session_path, alert: t("sessions.create.local_login_disabled")
          return
        end

        user = User.authenticate_by(email: params[:email], password: params[:password])
      else
        redirect_to new_session_path, alert: t("sessions.create.local_login_disabled")
        return
      end
    end

    if user
      if user.otp_required?
        log_super_admin_override_login(user)
        session[:mfa_user_id] = user.id
        redirect_to verify_mfa_path
      else
        log_super_admin_override_login(user)
        @session = create_session_for(user)
        redirect_to root_path
      end
    else
      flash.now[:alert] = t(".invalid_credentials")
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @session.destroy
    redirect_to new_session_path, notice: t(".logout_successful")
  end

  def openid_connect
    auth = request.env["omniauth.auth"]

    # Nil safety: ensure auth and required fields are present
    unless auth&.provider && auth&.uid
      redirect_to new_session_path, alert: t("sessions.openid_connect.failed")
      return
    end

    # Security fix: Look up by provider + uid, not just email
    oidc_identity = OidcIdentity.find_by(provider: auth.provider, uid: auth.uid)

    if oidc_identity
      # Existing OIDC identity found - authenticate the user
      user = oidc_identity.user
      oidc_identity.record_authentication!

      # MFA check: If user has MFA enabled, require verification
      if user.otp_required?
        session[:mfa_user_id] = user.id
        redirect_to verify_mfa_path
      else
        @session = create_session_for(user)
        redirect_to root_path
      end
    else
      # No existing OIDC identity - need to link to account
      # Store auth data in session and redirect to linking page
      session[:pending_oidc_auth] = {
        provider: auth.provider,
        uid: auth.uid,
        email: auth.info&.email,
        name: auth.info&.name,
        first_name: auth.info&.first_name,
        last_name: auth.info&.last_name
      }
      redirect_to link_oidc_account_path
    end
  end

  def failure
    redirect_to new_session_path, alert: t("sessions.failure.failed")
  end

  private
    def set_session
      @session = Current.user.sessions.find(params[:id])
    end

    def log_super_admin_override_login(user)
      # Only log when local login is globally disabled but an emergency
      # super-admin override is enabled.
      return if AuthConfig.local_login_enabled?
      return unless AuthConfig.local_admin_override_enabled?
      return unless user&.super_admin?

      Rails.logger.info("[AUTH] Super admin override login: user_id=#{user.id} email=#{user.email}")
    end

    def demo_host_match?(demo)
      return false unless demo.present? && demo["hosts"].present?

      demo["hosts"].include?(request.host)
    end
end
