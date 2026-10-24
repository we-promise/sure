# The cost of one lot of a holding's position. Only a lot a trade acquired is
# editable: the opening lot stays out of the position's figure, so a cost set
# on it would change nothing the user can see. A change is restated into the
# holdings straight away, as a price sync is.
class HoldingLotsController < ApplicationController
  before_action :set_holding
  before_action :require_holding_write_permission!
  before_action :set_lot

  def update
    total = lot_params[:total_cost_basis].presence&.to_d

    if total && total >= 0
      @lot.set_manual_total_cost!(total)
      restate
      flash[:notice] = t(".success")
    else
      flash[:alert] = t(".error")
    end

    redirect_to account_path(@holding.account, tab: "holdings")
  end

  def unlock
    @lot.unlock_cost!
    restate

    redirect_to account_path(@holding.account, tab: "holdings"), notice: t(".success")
  end

  private
    def set_holding
      @holding = Current.family.holdings
                   .joins(:account)
                   .merge(Account.accessible_by(Current.user))
                   .find(params[:holding_id])
    end

    def require_holding_write_permission!
      require_account_permission!(@holding.account)
    end

    def set_lot
      @lot = HoldingLot.derived.where(account_id: @holding.account_id, security_id: @holding.security_id).find(params[:id])
    end

    def lot_params
      params.require(:holding_lot).permit(:total_cost_basis)
    end

    def restate
      strategy = @holding.account.linked? ? :reverse : :forward
      Balance::Materializer.new(@holding.account, strategy: strategy, security_ids: [ @holding.security_id ]).materialize_balances
    end
end
