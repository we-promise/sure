class BrexItemsController < ApplicationController
  include RetiredProviderRouting
  self.retired_provider_key = "brex"

  before_action :set_brex_item, only: [ :show, :edit, :update, :destroy, :sync ]
  before_action :require_admin!, only: [ :new, :create, :edit, :update, :destroy, :sync ]
  rescue_from(*BrexItem::LegacyAccess::DENIAL_ERRORS, with: :render_ownership_changed)
  rescue_from ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, with: :render_ownership_changed

  def index
    @brex_items = legacy_brex_items
    render layout: "settings"
  end

  def show
  end

  def new
    @brex_item = Current.family.brex_items.build
  end

  def create
    @brex_item = BrexItem::Lifecycle.create(family: Current.family, actor: Current.user, attributes: brex_item_params)
    if @brex_item.persisted?
      render_provider_panel_success(t(".success"))
    else
      render_provider_panel_error
    end
  end

  def edit
    connection = Current.family.provider_connections.where(provider_key: "brex")
      .joins(:provider_migration_control).find_by(provider_migration_controls: {
        family_id: Current.family.id, legacy_type: "BrexItem", legacy_id: @brex_item.id, state: ProviderMigrationControl::NATIVE_STATES
      })
    redirect_to edit_provider_connection_path(connection) if connection
  end

  def update
    @brex_item = BrexItem::Lifecycle.new(item: @brex_item, actor: Current.user).update_settings(brex_item_params)
    if @brex_item.errors.empty?
      render_provider_panel_success(t(".success"))
    else
      render_provider_panel_error
    end
  end

  def destroy
    BrexItem::Lifecycle.new(item: @brex_item, actor: Current.user).disconnect
    redirect_to accounts_path, notice: t(".success")
  end

  def sync
    BrexItem::SyncRequest.new(item: @brex_item, actor: Current.user).call

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  private

    def render_ownership_changed(error)
      capture_ownership_failure(error)
      redirect_to settings_providers_path, alert: t("brex_items.lifecycle.unavailable"), status: :see_other
    end

    def capture_ownership_failure(error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warning", message: "Brex connection management refused",
        source: self.class.name, provider_key: "brex", family: Current.family,
        metadata: { action: action_name, brex_item_id: @brex_item&.id, error_class: error.class.name })
    rescue StandardError
      nil
    end

    def legacy_brex_items
      native_ids = ProviderMigrationControl.where(family: Current.family, legacy_type: "BrexItem",
        provider_key: "brex", state: ProviderMigrationControl::NATIVE_STATES).select(:legacy_id)
      Current.family.brex_items.active.where.not(id: native_ids).ordered
    end

    def render_provider_panel_success(message)
      return redirect_to accounts_path, notice: message, status: :see_other unless turbo_frame_request?

      flash.now[:notice] = message
      @brex_items = legacy_brex_items.includes(:syncs, :brex_accounts)
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
