class PasswordsController < ApplicationController
  def edit
  end

  def update
    if update_password_and_log_change
      redirect_to root_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

    def update_password_and_log_change
      ActiveRecord::Base.transaction do
        next false unless Current.user.update(password_params)

        SecurityAuditLog.log_password_changed!(user: Current.user, request: request)

        true
      end
    end

    def password_params
      params.require(:user).permit(:password, :password_confirmation, :password_challenge).with_defaults(password_challenge: "")
    end
end
