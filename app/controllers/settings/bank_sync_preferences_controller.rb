# Family-scoped bank sync preferences, surfaced in the provider drawers on
# Settings -> Bank sync. These are behavioural choices about how synced data is
# presented, so they live on Family rather than in the instance-wide provider
# configuration registry, which holds credentials.
class Settings::BankSyncPreferencesController < ApplicationController
  layout "settings"

  before_action :ensure_admin

  # Saves the preferences and, when a value actually changed, asks the relevant
  # provider to replay history so existing transactions reflect the new setting.
  #
  # @return [void] redirects to Settings -> Bank sync with a status notice
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
    # @return [ActionController::Parameters] the permitted family preference attributes
    def bank_sync_preferences_params
      params.require(:family).permit(:plaid_prefer_original_description)
    end

    # These preferences change how every member's transactions are named, so
    # they are restricted to family admins like the rest of the Bank sync page.
    #
    # @return [void] redirects non-admins to the root path
    def ensure_admin
      return if Current.user.admin?

      redirect_to root_path, alert: t("settings.providers.not_authorized")
    end
end
