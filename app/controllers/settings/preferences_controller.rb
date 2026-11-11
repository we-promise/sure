class Settings::PreferencesController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
    @family_members = Current.family.users.where.not(id: @user.id).where(active: true)
    @budget_shares = @user.budget_shares_given.index_by(&:viewer_id)
    @salary_series_options = Current.family.month_start_series_options_for(@user)
    # A salary on an account this user cannot see stays out of the auto-submitting
    # form, so their other changes never clear it.
    current_salary_id = Current.family.month_start_recurring_transaction_id
    @salary_series_editable = current_salary_id.nil? || @salary_series_options.any? { |series| series.id == current_salary_id }
  end

  # Writes per-user boolean preferences stored in the JSONB `users.preferences`
  # column. Mirrors Settings::AppearancesController#update so the toggle card on
  # the Preferences page can submit directly without going through the broader
  # UsersController#update flow (which expects a full user form payload).
  def update
    @user = Current.user
    user_params = params.permit(user: [ :preview_features_enabled ]).fetch(:user, {})

    @user.with_locked_preferences do |updated_prefs|
      if user_params.key?(:preview_features_enabled)
        updated_prefs["preview_features_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
      end
    end
    redirect_to settings_preferences_path
  end
end
