class Settings::PreferencesController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
    @family_members = Current.family.users.where.not(id: @user.id).where(active: true)
    @budget_shares = @user.budget_shares_given.index_by(&:viewer_id)
  end

  # Writes per-user boolean preferences stored in the JSONB `users.preferences`
  # column. Mirrors Settings::AppearancesController#update so the toggle card on
  # the Preferences page can submit directly without going through the broader
  # UsersController#update flow (which expects a full user form payload).
  def update
    @user = Current.user
    user_params = params.permit(user: [ :preview_features_enabled, :monthly_spending_visible ]).fetch(:user, {})

    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      if user_params.key?(:preview_features_enabled)
        updated_prefs["preview_features_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
      end
      if user_params.key?(:monthly_spending_visible) && @user.preview_features_enabled?
        hidden = !ActiveModel::Type::Boolean.new.cast(user_params[:monthly_spending_visible])
        sections = @user.dashboard_hidden_sections - [ "monthly_spending" ]
        sections << "monthly_spending" if hidden
        updated_prefs["hidden_sections"] = sections
      end
      @user.update!(preferences: updated_prefs)
    end
    redirect_to settings_preferences_path
  end
end
