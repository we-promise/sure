class Settings::SecuritiesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Security", nil ]
    ]
    @oidc_identities = Current.user.oidc_identities.order(:provider)
  end

  def update
    if Current.user.authenticate(password_params[:password_challenge])
      if Current.user.update(password_params.except(:password_challenge))
        redirect_to settings_security_path, notice: t(".success")
      else
        redirect_to settings_security_path, alert: Current.user.errors.full_messages.to_sentence
      end
    else
      redirect_to settings_security_path, alert: t(".invalid_current_password")
    end
  end

  private

    def password_params
      params.require(:user).permit(:password, :password_confirmation, :password_challenge)
    end
end
