class PasswordsController < ApplicationController
  before_action :ensure_password_change_allowed

  def edit
  end

  def update
    if update_password_and_log_change
      redirect_to root_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  rescue ActiveRecord::ActiveRecordError
    render :edit, status: :unprocessable_entity
  end

  private

    def update_password_and_log_change
      # has_secure_password ignores a blank password, so update would succeed without a change.
      if password_params[:password].blank?
        Current.user.errors.add(:password, :blank)
        return false
      end

      ActiveRecord::Base.transaction do
        next false unless Current.user.update(password_params)

        SecurityAuditLog.log_password_changed!(user: Current.user, request: request, actor: Current.true_user)

        true
      end
    end

    # Mirrors the local login policy: when only SSO is allowed, a local
    # password could not be used to sign in, so it must not be set here
    # either. Super admins keep this page under the local admin override,
    # since that override is exactly what lets them sign in with a password.
    def ensure_password_change_allowed
      return if AuthConfig.local_login_allowed_for?(Current.user)

      redirect_to root_path, alert: t("passwords.disabled")
    end

    def password_params
      params.require(:user).permit(:password, :password_confirmation, :password_challenge).with_defaults(password_challenge: "")
    end
end
