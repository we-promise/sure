class CommoditySalesController < ApplicationController
  before_action :set_item

  def new
    @sale = @item.sales.build(date: Date.current, quantity: @item.remaining_quantity, currency: @item.currency)
  end

  def create
    @sale = @item.sales.build(sale_params)

    if @sale.save
      redirect_to account_path(@item.account, tab: "inventory"), notice: t(".success")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @item.sales.find(params[:id]).destroy!
    redirect_to account_path(@item.account, tab: "inventory"), notice: t(".success")
  end

  private
    def set_item
      @item = Commodity::Item.where(account: Current.user.accessible_accounts).find(params[:commodity_item_id])
      require_account_permission!(@item.account)
    end

    def sale_params
      params.require(:commodity_sale).permit(:date, :quantity, :proceeds, :proceeds_basis, :costs, :currency)
    end
end
