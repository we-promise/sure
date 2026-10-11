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
    user_params = params.permit(user: [ :preview_features_enabled, :account_release_channel, :account_release_lead_days ]).fetch(:user, {})

    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      if user_params.key?(:preview_features_enabled)
        updated_prefs["preview_features_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
      end
      assign_account_release_preferences(updated_prefs, user_params)
      @user.update!(preferences: updated_prefs)
    end
    redirect_to settings_preferences_path
  end

  private
    # Unknown values are dropped rather than stored, so the getters on User
    # never meet a channel or lead time they cannot handle.
    def assign_account_release_preferences(prefs, user_params)
      channel = user_params[:account_release_channel]
      prefs["account_release_channel"] = channel if channel.in?(User::ACCOUNT_RELEASE_CHANNELS)

      return unless user_params.key?(:account_release_lead_days)

      days = Integer(user_params[:account_release_lead_days].to_s, exception: false)
      prefs["account_release_lead_days"] = days if days && Account::ReleaseReminder::LEAD_DAYS_RANGE.cover?(days)
    end
end
