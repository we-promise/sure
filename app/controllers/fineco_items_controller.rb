class FinecoItemsController < ApplicationController
  before_action :reject_impersonated_session
  before_action :require_self_hosted_fineco
  before_action :require_preview_features!
  before_action :require_admin!
  before_action :set_fineco_item

  def sync
    unless @fineco_item.syncable?
      redirect_back_or_to accounts_path, alert: t("fineco_items.sync.unavailable"), status: :see_other
      return
    end

    if @fineco_item.syncing?
      redirect_back_or_to accounts_path, notice: t("fineco_items.sync.already_running"), status: :see_other
    else
      @fineco_item.sync_later
      redirect_back_or_to accounts_path, notice: t("fineco_items.sync.queued"), status: :see_other
    end
  end

  def destroy
    @fineco_item.disconnect!
    redirect_to accounts_path, notice: t("fineco_items.destroy.success"), status: :see_other
  end

  private

    def reject_impersonated_session
      head :forbidden if Current.session&.active_impersonator_session_id.present?
    end

    def require_self_hosted_fineco
      head :not_found unless Rails.application.config.app_mode.self_hosted?
    end

    def set_fineco_item
      @fineco_item = Current.family.fineco_items.owned_by(Current.user).find(params[:id])
    end
end
