class Settings::SecuritiesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ t("shared.breadcrumbs.security", default: "Security"), nil ]
    ]
  end
end
