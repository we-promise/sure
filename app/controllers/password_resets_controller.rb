class PasswordResetsController < ApplicationController
  skip_authentication

  layout "auth"

  before_action :ensure_password_resets_enabled
  before_action :set_user_by_token, only: %i[edit update]

  def new
  end

  def create
    if (user = User.find_by(email: params[:email]))
      # Security: Block password reset for SSO-only users.
      # These users have no local password and must authenticate via SSO.
      unless user.sso_only?
        PasswordMailer.with(
          user: user,
          token: user.generate_token_for(:password_reset)
        ).password_reset.deliver_later
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

    if @user.update(password_params)
      redirect_to new_session_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

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
