class Settings::PreferencesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [ [ t("layouts.application.nav.home"), root_path ], [ t("settings.settings_nav.preferences_label"), nil ] ]
    @user = Current.user
  end
end
