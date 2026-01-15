class Settings::SecuritiesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ :"breadcrumbs.home", root_path ],
      [ :"breadcrumbs.security", nil ]
    ]
    @oidc_identities = Current.user.oidc_identities.order(:provider)
  end
end
