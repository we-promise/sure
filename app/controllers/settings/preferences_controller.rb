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
    user_params = params.permit(user: [ :preview_features_enabled ]).fetch(:user, {})
    family_params = params.permit(family: [ :treat_investment_contributions_as_transfers ]).fetch(:family, {})

    if family_params.key?(:treat_investment_contributions_as_transfers) && !@user.admin?
      raise ActiveRecord::RecordNotFound
    end

    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      if user_params.key?(:preview_features_enabled)
        updated_prefs["preview_features_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
      end
      @user.update!(preferences: updated_prefs)
      if family_params.key?(:treat_investment_contributions_as_transfers)
        @user.family.update!(
          treat_investment_contributions_as_transfers:
            ActiveModel::Type::Boolean.new.cast(family_params[:treat_investment_contributions_as_transfers])
        )
      end
    end
    redirect_to settings_preferences_path,
      notice: family_params.key?(:treat_investment_contributions_as_transfers) ?
        t(".investment_contributions.updated") : nil
  end
end
