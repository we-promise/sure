class CaAutoBankItemsController < ApplicationController
  include CaAutoBankAuthorization

  def sync
    item = owned_ca_auto_bank_items.find(params[:id])
    if item.ready_for_sync?
      if item.syncing?
        notice = t("ca_auto_bank.sync_already_running")
      elsif item.sync_cooldown?
        notice = item.sync_cooldown_message
      else
        sync = item.sync_later
        notice = sync ? t("ca_auto_bank.sync_queued") : (item.sync_cooldown_message || t("ca_auto_bank.sync_unavailable"))
      end
      redirect_to settings_providers_path(anchor: "ca-auto-bank"), notice: notice, status: :see_other
    else
      redirect_to ca_auto_bank_login_path, alert: t("ca_auto_bank.errors.session_expired"), status: :see_other
    end
  end

  def destroy
    owned_ca_auto_bank_items.find(params[:id]).disconnect!
    redirect_to settings_providers_path(anchor: "ca-auto-bank"), notice: t("ca_auto_bank.disconnected"), status: :see_other
  end
end
