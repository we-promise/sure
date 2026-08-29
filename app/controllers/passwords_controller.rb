class PasswordsController < ApplicationController
  def edit
  end

  def update
    if Current.user.update(password_params)
      SecurityAuditLog.log_password_changed!(user: Current.user, request: request)
      redirect_to root_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

    def password_params
      params.require(:user).permit(:password, :password_confirmation, :password_challenge).with_defaults(password_challenge: "")
    end
end
