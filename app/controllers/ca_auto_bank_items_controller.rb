class CaAutoBankItemsController < ApplicationController
  include CaAutoBankAuthorization

  def sync
    item = owned_ca_auto_bank_items.find(params[:id])
    if item.ready_for_sync?
      item.sync_later unless item.syncing?
      redirect_to settings_providers_path(anchor: "ca-auto-bank"), notice: t("ca_auto_bank.sync_queued"), status: :see_other
    else
      redirect_to ca_auto_bank_login_path, alert: t("ca_auto_bank.errors.session_expired"), status: :see_other
    end
  end

  def destroy
    owned_ca_auto_bank_items.find(params[:id]).disconnect!
    redirect_to settings_providers_path(anchor: "ca-auto-bank"), notice: t("ca_auto_bank.disconnected"), status: :see_other
  end
end
