class Settings::BankSyncPreferencesController < ApplicationController
  layout "settings"

  before_action :ensure_admin

  def update
    family = Current.family
    prefer_original = ActiveModel::Type::Boolean.new.cast(
      bank_sync_preferences_params[:plaid_prefer_original_description]
    )
    changed = family.plaid_prefer_original_description? != prefer_original

    family.update!(plaid_prefer_original_description: prefer_original)

    # Only replay history when the preference actually flipped — re-saving the
    # same value shouldn't cost a full re-pull.
    family.resync_plaid_items! if changed

    redirect_to settings_providers_path, notice: t(changed ? ".updated_and_resyncing" : ".updated")
  end

  private
    def bank_sync_preferences_params
      params.require(:family).permit(:plaid_prefer_original_description)
    end

    def ensure_admin
      return if Current.user.admin?

      redirect_to root_path, alert: t("settings.providers.not_authorized")
    end
end
