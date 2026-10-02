class Settings::PreferencesController < ApplicationController
  layout "settings"

  def show
    @user ||= Current.user
    @family_members = Current.family.users.where.not(id: @user.id).where(active: true)
    @budget_shares = @user.budget_shares_given.index_by(&:viewer_id)
  end

  # Writes per-user preferences stored in the JSONB `users.preferences` column.
  # Mirrors Settings::AppearancesController#update so the cards on the
  # Preferences page can submit directly without going through the broader
  # UsersController#update flow (which expects a full user form payload).
  def update
    @user = Current.user
    user_params = params.permit(user: [ :preview_features_enabled, :assistant_notes ]).fetch(:user, {})

    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      if user_params.key?(:preview_features_enabled)
        updated_prefs["preview_features_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
      end
      @user.preferences = updated_prefs
      @user.assistant_notes = user_params[:assistant_notes] if user_params.key?(:assistant_notes)
      @user.save!
    end

    notice = t(".assistant_notes_saved") if user_params.key?(:assistant_notes)
    redirect_to settings_preferences_path, notice: notice
  rescue ActiveRecord::RecordInvalid
    # Re-render rather than redirect so rejected notes aren't lost.
    flash.now[:alert] = @user.errors.full_messages.to_sentence
    show
    render :show, status: :unprocessable_entity
  end
end
