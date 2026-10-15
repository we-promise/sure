# Commodity accounts are containers for inventory items. `new` is the second
# step of the "add" modal (pick a metal); items are created through
# CommodityItemsController, which creates the account on first save.
class CommoditiesController < ApplicationController
  before_action :set_manageable_account, only: %i[edit update]

  def new
    @metals = Commodity.metals
  end

  def edit
  end

  def update
    currency_changed = account_params[:currency].present? && account_params[:currency] != @account.currency

    if @account.update(account_params)
      @account.sync_later if currency_changed
      redirect_back_or_to account_path(@account), notice: t(".success")
    else
      @error_message = @account.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_manageable_account
      @account = Current.user.accessible_accounts.where(accountable_type: "Commodity").find(params[:id])
      require_account_permission!(@account)
    end

    def account_params
      params.require(:account).permit(:name, :currency, :institution_name, :notes, :exclude_from_reports)
    end
end
