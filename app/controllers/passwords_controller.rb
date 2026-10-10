class PasswordsController < ApplicationController
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

    def password_params
      params.require(:user).permit(:password, :password_confirmation, :password_challenge).with_defaults(password_challenge: "")
    end
end
