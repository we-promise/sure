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
      render_provider_panel_success(t(".success"))
    else
      render_provider_panel_error
    end
  end

  def edit
  end

  def update
    if BrexItem::AccountFlow.update_item_with_cache_expiration(@brex_item, family: Current.family, attributes: brex_item_params)
      render_provider_panel_success(t(".success"))
    else
      render_provider_panel_error
    end
  end

  def destroy
    @brex_item.unlink_all!(dry_run: false)
    @brex_item.destroy_later
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    @brex_item.sync_later unless @brex_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  private

    def render_provider_panel_success(message)
      return redirect_to accounts_path, notice: message, status: :see_other unless turbo_frame_request?

      flash.now[:notice] = message
      @brex_items = Current.family.brex_items.active.ordered.includes(:syncs, :brex_accounts)
      render_brex_provider_panel(locals: { brex_items: @brex_items }, include_flash: true)
    end

    def render_provider_panel_error
      @error_message = @brex_item.errors.full_messages.join(", ")
      return redirect_to settings_providers_path, alert: @error_message, status: :see_other unless turbo_frame_request?

      render_brex_provider_panel(locals: { error_message: @error_message }, status: :unprocessable_entity)
    end

    def render_brex_provider_panel(locals:, status: :ok, include_flash: false)
      streams = [
        turbo_stream.replace(
          "brex-providers-panel",
          partial: "settings/providers/brex_panel",
          locals: locals
        )
      ]
      streams += flash_notification_stream_items if include_flash
      render turbo_stream: streams, status: status
    end

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
