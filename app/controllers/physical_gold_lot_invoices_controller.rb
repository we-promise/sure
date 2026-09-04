class PhysicalGoldLotInvoicesController < ApplicationController
  before_action :set_lot
  before_action :require_owner_permission!, only: :destroy

  def show
    raise ActiveRecord::RecordNotFound unless @lot.invoice.attached?

    disposition = params[:disposition] == "attachment" ? "attachment" : "inline"
    redirect_to rails_blob_url(@lot.invoice, disposition: disposition)
  end

  def destroy
    @lot.invoice.purge
    redirect_to edit_physical_gold_lot_path(@lot), notice: t(".deleted")
  end

  private
    def set_lot
      @lot = PhysicalGoldLot.joins(:account).merge(Current.user.accessible_accounts).find(params[:physical_gold_lot_id])
      raise ActiveRecord::RecordNotFound unless @lot.account.investment&.physical_gold?
    end

    def require_owner_permission!
      require_account_permission!(@lot.account)
    end
end
