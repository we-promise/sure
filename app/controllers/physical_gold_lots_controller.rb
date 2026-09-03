class PhysicalGoldLotsController < ApplicationController
  before_action :set_account, only: %i[new create]
  before_action :set_lot, only: %i[edit update destroy]

  def new
    @lot = @account.physical_gold_lots.build(acquired_on: Date.current, currency: @account.currency)
  end

  def create
    @lot = @account.physical_gold_lots.build(lot_params.merge(currency: @account.currency))
    if @lot.save
      redirect_to account_path(@account, tab: "overview"), notice: t(".success")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @account = @lot.account
  end

  def update
    if @lot.update(lot_params.merge(currency: @lot.account.currency))
      redirect_to account_path(@lot.account, tab: "overview"), notice: t(".success")
    else
      @account = @lot.account
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    account = @lot.account
    @lot.destroy!
    redirect_to account_path(account, tab: "overview"), notice: t(".deleted")
  end

  private
    def set_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
      return unless require_account_permission!(@account)

      raise ActiveRecord::RecordNotFound unless @account.investment? && @account.investment.physical_gold?
    end

    def set_lot
      @lot = PhysicalGoldLot.joins(:account).merge(Current.user.accessible_accounts).find(params[:id])
      return unless require_account_permission!(@lot.account)

      raise ActiveRecord::RecordNotFound unless @lot.account.investment&.physical_gold?
    end

    def lot_params
      params.require(:physical_gold_lot).permit(:description, :acquired_on, :weight, :weight_unit, :karat, :cost_amount, :making_charge, :manual_value, :notes, :merchant_id)
    end
end
