class Settings::AppearancesController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
  end

  # Updates the submitted Appearance preferences under a pessimistic
  # user-row lock. Account-group selections are filtered to known accountable
  # keys; preferences omitted from the form are preserved as-is.
  def update
    @user = Current.user
    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      updated_prefs["show_split_grouped"] = params.dig(:user, :show_split_grouped) == "1" if params.dig(:user, :show_split_grouped)
      updated_prefs["dashboard_two_column"] = params.dig(:user, :dashboard_two_column) == "1" if params.dig(:user, :dashboard_two_column)
      updated_prefs["disable_modal_click_outside"] = params.dig(:user, :disable_modal_click_outside) == "1" if params.dig(:user, :disable_modal_click_outside)
      # "Always expand" account groups on the dashboard balance sheet. The form
      # posts one checkbox per accountable type; unchecked boxes are hidden
      # fields that submit an empty string, so when the checkboxes are in the
      # form the param is always present (an array, possibly empty). We only
      # write it when present so a form that omits the checkboxes (e.g. a
      # two-column-only form) never wipes the stored selection.
      if (account_groups = params.dig(:user, :account_groups))
        # Unchecked boxes arrive as empty strings (one per hidden field); keep
        # only the actually-selected keys, and validate against known types so
        # arbitrary strings can't be injected into the JSONB column.
        valid_keys = Accountable::TYPES.map(&:underscore)
        selected = (account_groups.is_a?(Array) ? account_groups : [ account_groups ])
        updated_prefs["always_expanded_account_groups"] = selected.select { |k| valid_keys.include?(k) }
      end
      @user.update!(preferences: updated_prefs)
    end
    redirect_to settings_appearance_path
  end
end
