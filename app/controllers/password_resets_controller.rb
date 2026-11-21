class PasswordResetsController < ApplicationController
  skip_authentication

  layout "auth"

  before_action :ensure_password_resets_enabled
  before_action :set_user_by_token, only: %i[edit update]

  def new
  end

  def create
    if (user = User.find_by_email_with_legacy_fallback(params[:email]))
      # Security: Block password reset for SSO-only users.
      # These users have no local password and must authenticate via SSO.
      unless user.sso_only?
        # The mailer generates the token itself; passing it here would serialize
        # it into the delivery job's logged arguments.
        PasswordMailer.with(user: user).password_reset.deliver_later
      end
    end

    # Always redirect to pending step to prevent email enumeration
    redirect_to new_password_reset_path(step: "pending")
  end

  def edit
    @user = User.new
  end

  def update
    # Security: Block password setting for SSO-only users.
    # Defense-in-depth: even if they somehow get a reset token, block the update.
    if @user.sso_only?
      redirect_to new_session_path, alert: t("password_resets.sso_only_user")
      return
    end

    if update_password_and_log_change
      redirect_to new_session_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  rescue ActiveRecord::ActiveRecordError
    render :edit, status: :unprocessable_entity
  end

  # Bridges the HTTPS reset link in the email to the app's custom scheme so the
  # native reset screen opens. Renders in the shared auth layout and meta-refreshes
  # to sureapp://password-reset, with a design-system fallback link to tap.
  # Analytics is suppressed (@skip_analytics) so the token-bearing URL is never
  # captured by PostHog.
  def mobile_redirect
    @skip_analytics = true
    @token = params[:token].to_s
    @deep_link = "sureapp://password-reset?token=#{ERB::Util.url_encode(@token)}"
  end

  private

    def update_password_and_log_change
      # has_secure_password ignores a blank password, so update would succeed without a change.
      if password_params[:password].blank?
        @user.errors.add(:password, :blank)
        return false
      end

      ActiveRecord::Base.transaction do
        next false unless @user.update(password_params)

        SecurityAuditLog.log_password_changed!(user: @user, request: request)
        # The user is signed out on this path, so every session goes
        # (CWE-613). User#revoke_oauth_access has already revoked every OAuth
        # token (mobile app included) as part of the update.
        @user.sessions.destroy_all

        true
      end
    end

    def ensure_password_resets_enabled
      return if AuthConfig.password_features_enabled?

      redirect_to new_session_path, alert: t("password_resets.disabled")
    end

    def set_user_by_token
      @user = User.find_by_token_for(:password_reset, params[:token])
      redirect_to new_password_reset_path, alert: t("password_resets.update.invalid_token") unless @user.present?
    end

    def password_params
      params.require(:user).permit(:password, :password_confirmation)
    end
end
