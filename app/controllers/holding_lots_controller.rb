# The cost of one lot of a holding's position. Only a lot a trade acquired is
# editable: the opening lot stays out of the position's figure, so a cost set
# on it would change nothing the user can see. Nor can a cost be set on any
# lot while the provider supplies the position's cost, since restatement
# leaves the provider's rows alone; a cost set earlier can still be cleared,
# as fifo disposals still read it. A change is restated into the holdings
# straight away, as a price sync is, and the two commit together or not at
# all.
class HoldingLotsController < ApplicationController
  before_action :set_holding
  before_action :require_holding_write_permission!
  before_action :refuse_provider_cost!, only: :update
  before_action :set_lot

  def update
    # Strict, since String#to_d reads "abc" as 0 and "12abc" as 12.
    total = BigDecimal(lot_params[:total_cost_basis].to_s, exception: false)

    # The provider-cost refusal is checked again under the lock, against the
    # holding as it is now.
    updated = total && restating { !@holding.provider_cost_position? && @lot.update(manual_total_cost: total) }

    if updated
      flash[:notice] = t(".success")
    else
      flash[:alert] = t(".error")
    end

    redirect_to account_path(@holding.account, tab: "holdings")
  end

  def unlock
    restating { @lot.unlock_cost! }

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

    def refuse_provider_cost!
      return unless @holding.provider_cost_position?

      redirect_to account_path(@holding.account, tab: "holdings"), alert: t("holding_lots.provider_cost")
    end

    def set_lot
      @lot = HoldingLot.derived.where(account_id: @holding.account_id, security_id: @holding.security_id).find(params[:id])
    end

    def lot_params
      params.require(:holding_lot).permit(:total_cost_basis)
    end

    # Changes the lot and restates the position in one transaction under the
    # account row lock, taken first as a sync takes it, so a failed
    # restatement rolls the lot back and an edit and a sync of the same account
    # do not interleave. The holding and the lot are read again once the lock
    # is held, since a remap may have moved them while the request waited.
    # Restates only when the change is saved; returns whether it was.
    def restating
      account = @holding.account

      account.with_lock do
        @holding.reload
        set_lot
        changed = yield
        if changed
          strategy = account.linked? ? :reverse : :forward
          Balance::Materializer.new(account, strategy: strategy, security_ids: [ @holding.security_id ]).materialize_balances
        end
        changed
      end
    end
end
