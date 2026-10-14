class PasswordsController < ApplicationController
  def edit
  end

  def update
    if Current.user.update(password_params)
      # Whoever knew the old password must not stay signed in elsewhere; keep this session.
      Current.user.sessions.where.not(id: Current.session&.id).destroy_all
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
