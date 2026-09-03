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
      @user.update!(preferences: updated_prefs)
    end

    # Family-wide (not a per-user preference, unlike the toggles above): it
    # controls what gets written to shared transaction data regardless of
    # which family member is logged in, so only an admin may change it --
    # same restriction as the other family-level settings in UsersController.
    if @user.admin? && params.dig(:family, :auto_generate_transaction_names)
      Current.family.update!(auto_generate_transaction_names: params.dig(:family, :auto_generate_transaction_names) == "1")
    end

    redirect_to settings_appearance_path
  end
end
