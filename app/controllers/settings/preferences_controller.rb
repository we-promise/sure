class Settings::PreferencesController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
    @family = Current.family
  end

  # Writes per-user boolean preferences stored in the JSONB `users.preferences`
  # column, plus per-family module toggles in `families.disabled_modules`. The
  # auto-submit pattern matches Settings::AppearancesController#update.
  def update
    @user = Current.user
    user_params = params.permit(user: [ :preview_features_enabled ]).fetch(:user, {})
    module_params = params.permit(family: { modules: {} }).dig(:family, :modules)

    ActiveRecord::Base.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      if user_params.key?(:preview_features_enabled)
        updated_prefs["preview_features_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
      end
      @user.update!(preferences: updated_prefs)

      if module_params.present?
        family = Current.family
        family.lock!
        disabled = Array(family.disabled_modules).map(&:to_s)
        module_params.each do |name, enabled|
          name = name.to_s
          next unless Family::AVAILABLE_MODULES.include?(name)
          if ActiveModel::Type::Boolean.new.cast(enabled)
            disabled.delete(name)
          else
            disabled << name unless disabled.include?(name)
          end
        end
        family.update!(disabled_modules: disabled)
      end
    end
    redirect_to settings_preferences_path
  end
end
