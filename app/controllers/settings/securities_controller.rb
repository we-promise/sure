class Settings::SecuritiesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Security", nil ]
    ]
    @recent_sessions = Current.user.sessions.order(created_at: :desc).limit(5)
  end
end
