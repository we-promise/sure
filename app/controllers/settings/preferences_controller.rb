class Settings::PreferencesController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
  end

  # Writes per-user boolean preferences stored in the JSONB `users.preferences`
  # column. Mirrors Settings::AppearancesController#update so the toggle card on
  # the Preferences page can submit directly without going through the broader
  # UsersController#update flow (which expects a full user form payload).
  def update
    @user = Current.user
    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      if params.dig(:user, :preview_features_enabled)
        updated_prefs["preview_features_enabled"] = params.dig(:user, :preview_features_enabled) == "1"
      end
      @user.update!(preferences: updated_prefs)
    end
    redirect_to settings_preferences_path
  end
end
