class ScalableCapitalItemsController < ApplicationController
  before_action :require_admin
  before_action :require_configured, only: %i[create sync]
  before_action :require_preview_features!, only: :create
  before_action :set_item, only: %i[sync destroy]

  def create
    attributes = params.expect(scalable_capital_item: %i[portfolio_id savings_id])
    item = Current.family.scalable_capital_items.create!(
      owner: Current.user,
      portfolio_id: attributes[:portfolio_id].to_s.strip,
      savings_id: attributes[:savings_id].to_s.strip.presence
    )
    item.sync_later
    redirect_to bank_sync_path, notice: t(".started")
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    redirect_to bank_sync_path, alert: t(".invalid")
  end

  def sync
    @item.sync_later
    redirect_back fallback_location: bank_sync_path, notice: t(".started")
  end

  def destroy
    @item.with_lock { @item.destroy! }
    redirect_to bank_sync_path, notice: t(".disconnected"), status: :see_other
  end

  private

    def require_admin
      return if Current.user.admin?

      redirect_to root_path, alert: t("settings.providers.not_authorized")
    end

    def require_configured
      return if ScalableCapitalItem.configured_family_id == Current.family.id

      redirect_to bank_sync_path, alert: t("scalable_capital_items.disabled")
    end

    def set_item
      @item = Current.family.scalable_capital_items.find(params[:id])
    end

    def bank_sync_path
      settings_providers_path(anchor: "scalable-capital-connection")
    end
end
