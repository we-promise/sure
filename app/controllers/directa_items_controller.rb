class DirectaItemsController < ApplicationController
  before_action :disable_caching
  before_action :reject_impersonated_session
  before_action :require_self_hosted_directa
  before_action :require_preview_features!
  before_action :require_admin!
  before_action :set_directa_item

  def sync
    unless @directa_item.syncable?
      redirect_back_or_to settings_providers_path(anchor: "directa"),
        alert: t("directa_items.sync.unavailable"),
        status: :see_other
      return
    end

    if @directa_item.syncing?
      redirect_back_or_to settings_providers_path(anchor: "directa"),
        notice: t("directa_items.sync.already_running"),
        status: :see_other
    else
      @directa_item.sync_later
      redirect_back_or_to settings_providers_path(anchor: "directa"),
        notice: t("directa_items.sync.queued"),
        status: :see_other
    end
  end

  def destroy
    @directa_item.disconnect!
    redirect_to settings_providers_path(anchor: "directa"),
      notice: t("directa_items.destroy.success"),
      status: :see_other
  end

  private

    def set_directa_item
      @directa_item = Current.family.directa_items.owned_by(Current.user).find(params[:id])
    end

    def disable_caching
      response.headers["Cache-Control"] = "no-store, private, max-age=0"
      response.headers["Pragma"] = "no-cache"
      response.headers["Referrer-Policy"] = "no-referrer"
    end

    def reject_impersonated_session
      head :forbidden if Current.session&.active_impersonator_session_id.present?
    end

    def require_self_hosted_directa
      head :not_found unless Rails.application.config.app_mode.self_hosted? && Current.family.can_connect_directa?
    end
end
