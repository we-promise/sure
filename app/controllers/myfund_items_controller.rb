class MyfundItemsController < ApplicationController
  before_action :set_myfund_item, only: [ :update, :destroy, :sync ]

  def create
    @myfund_item = Current.family.myfund_items.build(myfund_params)
    @myfund_item.name ||= "myFund.pl"

    if @myfund_item.save
      @myfund_item.sync_later

      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @myfund_items = Current.family.myfund_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "myfund-providers-panel",
            partial: "settings/providers/myfund_panel",
            locals: { myfund_items: @myfund_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @myfund_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "myfund-providers-panel",
          partial: "settings/providers/myfund_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @myfund_item.update(myfund_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success")
        @myfund_items = Current.family.myfund_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "myfund-providers-panel",
            partial: "settings/providers/myfund_panel",
            locals: { myfund_items: @myfund_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @myfund_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "myfund-providers-panel",
          partial: "settings/providers/myfund_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @myfund_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  def sync
    unless @myfund_item.syncing?
      @myfund_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to settings_providers_path, notice: t(".success") }
      format.json { head :ok }
    end
  end

  private

    def set_myfund_item
      @myfund_item = Current.family.myfund_items.find(params[:id])
    end

    def myfund_params
      params.require(:myfund_item).permit(:api_key, :portfolio_name, :name)
    end
end
