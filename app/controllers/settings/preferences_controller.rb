class Settings::PreferencesController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.preferences"), nil ]
    ]
  end
end
