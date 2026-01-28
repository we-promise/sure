class Settings::SecuritiesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Security", nil ]
    ]
    @oidc_identities = Current.user.oidc_identities.order(:provider)
  end
end
