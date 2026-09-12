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
      updated_prefs["disable_modal_click_outside"] = params.dig(:user, :disable_modal_click_outside) == "1" if params.dig(:user, :disable_modal_click_outside)

      if params.dig(:user, :transactions_compact)
        updated_prefs["transactions_compact"] = params.dig(:user, :transactions_compact) == "1"
      end

      if params.dig(:user, :transactions_group_by_date)
        updated_prefs["transactions_group_by_date"] = params.dig(:user, :transactions_group_by_date) == "1"
      end

      if params.dig(:user, :transactions_per_page)
        per_page = params.dig(:user, :transactions_per_page).to_i
        allowed = [ 10, 20, 30, 50, 100 ]
        updated_prefs["transactions_per_page"] = per_page if allowed.include?(per_page)
      end

      @user.update!(preferences: updated_prefs)
    end
    redirect_to settings_appearance_path
  end
end
