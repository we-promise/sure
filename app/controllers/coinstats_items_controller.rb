class CoinstatsItemsController < ApplicationController
  before_action :set_coinstats_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def index
    @coinstats_items = Current.family.coinstats_items.ordered
  end

  def show
  end

  def new
    @coinstats_item = Current.family.coinstats_items.build
  end

  def create
    @coinstats_item = Current.family.coinstats_items.build(coinstats_item_params)
    @coinstats_item.name ||= "CoinStats Connection"

    if @coinstats_item.save
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured CoinStats.")
        @coinstats_items = Current.family.coinstats_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "coinstats-providers-panel",
            partial: "settings/providers/coinstats_panel",
            locals: { coinstats_items: @coinstats_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @coinstats_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "coinstats-providers-panel",
          partial: "settings/providers/coinstats_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def edit
  end

  def update
    if @coinstats_item.update(coinstats_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated CoinStats configuration.")
        @coinstats_items = Current.family.coinstats_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "coinstats-providers-panel",
            partial: "settings/providers/coinstats_panel",
            locals: { coinstats_items: @coinstats_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @coinstats_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "coinstats-providers-panel",
          partial: "settings/providers/coinstats_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @coinstats_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled CoinStats connection for deletion.")
  end

  def sync
    unless @coinstats_item.syncing?
      @coinstats_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def setup_accounts
    render layout: false
  end

  def complete_account_setup
    # TODO: Complete the account setup process
    redirect_to accounts_path, alert: "Not implemented yet"
  end

  private

    def set_coinstats_item
      @coinstats_item = Current.family.coinstats_items.find(params[:id])
    end

    def coinstats_item_params
      params.require(:coinstats_item).permit(
        :name,
        :sync_start_date,
        :api_key
      )
    end
end
