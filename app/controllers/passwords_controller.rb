class PasswordsController < ApplicationController
  before_action :ensure_password_change_allowed

  def edit
  end

  def update
    if Current.user.update(password_params.merge(require_password_complexity: true))
      redirect_to root_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

    # Mirrors the local login policy: when only SSO is allowed, a local
    # password could not be used to sign in, so it must not be set here
    # either. Super admins keep this page under the local admin override,
    # since that override is exactly what lets them sign in with a password.
    def ensure_password_change_allowed
      return if AuthConfig.local_login_allowed_for?(Current.user)

      redirect_to root_path, alert: t("passwords.disabled")
    end

    # A missing or null current password becomes "", so the model always
    # checks it; nil would skip that validation.
    def password_params
      permitted = params.require(:user).permit(:password, :password_confirmation, :password_challenge)
      permitted.merge(password_challenge: permitted[:password_challenge].to_s)
    end
end
