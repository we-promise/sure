class Settings::SecuritiesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Security", nil ]
    ]
    @oidc_identities = Current.user.oidc_identities.order(:provider)
    @webauthn_credentials = Current.user.webauthn_credentials.order(created_at: :asc)
  end
end
