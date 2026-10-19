class ScalableItemsController < ApplicationController
  include ScalableAuthorization

  before_action :set_scalable_item

  def sync
    unless @scalable_item.ready_for_sync?
      redirect_to scalable_login_path, alert: t("scalable_items.sync.unavailable"), status: :see_other
      return
    end

    if @scalable_item.syncing?
      redirect_to settings_providers_path(anchor: "scalable"), notice: t("scalable_items.sync.already_running"), status: :see_other
    elsif !@scalable_item.sync_due?
      redirect_to settings_providers_path(anchor: "scalable"), notice: t("scalable_items.sync.cooldown"), status: :see_other
    else
      @scalable_item.sync_later
      redirect_to settings_providers_path(anchor: "scalable"), notice: t("scalable_items.sync.queued"), status: :see_other
    end
  end

  def destroy
    @scalable_item.disconnect!
    redirect_to settings_providers_path(anchor: "scalable"), notice: t("scalable_items.destroy.success"), status: :see_other
  end

  private

    def set_scalable_item
      @scalable_item = owned_scalable_items.find(params[:id])
    end
end
