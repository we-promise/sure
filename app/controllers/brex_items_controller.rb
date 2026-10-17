class BrexItemsController < ApplicationController
  before_action :set_brex_item, only: [ :show, :edit, :update, :destroy, :sync ]
  before_action :require_admin!, only: [ :new, :create, :edit, :update, :destroy, :sync ]

  def index
    @brex_items = Current.family.brex_items.active.ordered
    render layout: "settings"
  end

  def show
  end

  def new
    @brex_item = Current.family.brex_items.build
  end

  def create
    @brex_item = Current.family.brex_items.build(brex_item_params)
    @brex_item.name = t("brex_items.default_connection_name") if @brex_item.name.blank?

    if @brex_item.save
      @brex_item.sync_later
      redirect_to accounts_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("brex", alert: @brex_item.errors.full_messages.join(", "))
    end
  end

  def edit
  end

  def update
    if BrexItem::AccountFlow.update_item_with_cache_expiration(@brex_item, family: Current.family, attributes: brex_item_params)
      render_provider_panel("brex", notice: t(".success"), fallback_path: accounts_path,
                            brex_items: Current.family.brex_items.active.ordered.includes(:syncs, :brex_accounts))
    else
      render_provider_panel("brex", alert: @brex_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @brex_item.unlink_all!(dry_run: false)
    @brex_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    @brex_item.sync_later unless @brex_item.syncing?
    return render_provider_panel("brex", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  private

    def set_brex_item
      @brex_item = Current.family.brex_items.find(params[:id])
    end

    def brex_item_params
      permitted = params.require(:brex_item).permit(:name, :sync_start_date, :token, :base_url)
      permitted.delete(:token) if @brex_item&.persisted? && permitted[:token].blank?
      permitted[:token] = permitted[:token].to_s.strip if permitted[:token].present?
      if permitted.key?(:base_url)
        permitted[:base_url] = permitted[:base_url].to_s.strip
        permitted[:base_url] = nil if permitted[:base_url].blank?
      end
      permitted
    end
end
