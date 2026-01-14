# frozen_string_literal: true

class Settings::SsoIdentitiesController < ApplicationController
  layout "settings"

  def destroy
    @identity = Current.user.oidc_identities.find(params[:id])

    # Prevent unlinking last identity if user has no password
    if Current.user.oidc_identities.count == 1 && Current.user.password_digest.blank?
      redirect_to settings_security_path, alert: t(".cannot_unlink_last")
      return
    end

    provider_name = @identity.provider
    @identity.destroy!

    # Log account unlinking
    SsoAuditLog.log_unlink!(
      user: Current.user,
      provider: provider_name,
      request: request
    )

    redirect_to settings_security_path, notice: t(".success", provider: provider_name)
  end
end
