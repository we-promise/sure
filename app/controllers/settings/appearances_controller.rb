class Settings::AppearancesController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
  end

  def update
    @user = Current.user
    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      updated_prefs["show_split_grouped"] = params.dig(:user, :show_split_grouped) == "1" if params.dig(:user, :show_split_grouped)
      updated_prefs["dashboard_two_column"] = params.dig(:user, :dashboard_two_column) == "1" if params.dig(:user, :dashboard_two_column)
      @user.update!(preferences: updated_prefs)
    end
    redirect_to settings_appearance_path
  end
end
