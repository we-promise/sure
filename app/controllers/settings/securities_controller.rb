class Settings::SecuritiesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.securities"), nil ]
    ]
    @oidc_identities = Current.user.oidc_identities.order(:provider)
  end
end
