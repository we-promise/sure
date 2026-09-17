class ValuableItemsController < ApplicationController
  before_action :set_account, only: %i[new create]
  before_action :set_lot, only: %i[edit update destroy]

  def new
    @lot = @account.valuable.items.build(acquired_on: Date.current, currency: @account.currency, item_type: "bullion", material: "gold", weight_unit: "gram")
  end

  def create
    @lot = @account.valuable.lots.build(lot_params.merge(currency: @account.currency))
    @lot.skip_queued_valuation_refresh = true
    if @lot.save
      redirect_after_valuation(@account, t(".success"), valuation_activity_name(:purchase_added, @lot))
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @account = @lot.account
  end

  def update
    @lot.skip_queued_valuation_refresh = true
    if @lot.update(lot_params.merge(currency: @lot.account.currency))
      redirect_after_valuation(@lot.account, t(".success"), valuation_activity_name(:purchase_updated, @lot))
    else
      @account = @lot.account
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    account = @lot.account
    @lot.skip_queued_valuation_refresh = true
    activity_name = valuation_activity_name(:purchase_removed, @lot)
    @lot.destroy!
    redirect_after_valuation(account, t(".deleted"), activity_name)
  end

  private
    def refresh_valuation(account, reconciliation_name)
      ValuableValuation.new(account:, reconciliation_name:).refresh!
      true
    rescue ValuableValuation::Error, ActiveRecord::RecordInvalid => error
      RefreshValuableValuationJob.perform_later(account.id)
      DebugLogEntry.capture(
        category: "valuable_valuation", level: "warn", message: error.message,
        source: "ValuableItemsController#refresh_valuation",
        family: account.family, account: account, metadata: { account_id: account.id }
      )
      false
    end

    def redirect_after_valuation(account, success_message, reconciliation_name)
      if refresh_valuation(account, reconciliation_name)
        redirect_to account_path(account, tab: "overview"), notice: success_message
      else
        redirect_to account_path(account, tab: "overview"), alert: t("valuables.refresh_valuation.failure")
      end
    end

    def valuation_activity_name(action, item)
      I18n.t(
        "valuables.activity.#{action}",
        material: I18n.t("valuable_items.materials.#{item.material}"),
        description: item.description
      )
    end

    def set_account
      @account = Current.user.accessible_accounts.find(params[:account_id])
      return unless require_account_permission!(@account)

      raise ActiveRecord::RecordNotFound unless @account.valuable?
    end

    def set_lot
      @lot = ValuableItem.joins(:account).merge(Current.user.accessible_accounts).find(params[:id])
      return unless require_account_permission!(@lot.account)

      raise ActiveRecord::RecordNotFound unless @lot.account.valuable?
    end

    def lot_params
      params.require(:valuable_item).permit(:description, :acquired_on, :item_type, :material, :weight, :weight_unit, :purity, :karat, :cost_amount, :making_charge, :manual_value, :notes, :merchant_id, :invoice)
    end
end
