class HoldingsController < ApplicationController
  before_action :set_holding, only: %i[show update destroy unlock_cost_basis remap_security reset_security]

  def index
    @account = Current.family.accounts.find(params[:account_id])
  end

  def show
  end

  def update
    total_cost_basis = holding_params[:cost_basis].to_d

    if total_cost_basis >= 0 && @holding.qty.positive?
      # Convert total cost basis to per-share cost (the cost_basis field stores per-share)
      # Zero is valid for gifted/inherited shares
      per_share_cost = total_cost_basis / @holding.qty
      @holding.set_manual_cost_basis!(per_share_cost)
      flash[:notice] = t(".success")
    else
      flash[:alert] = t(".error")
    end

    # Redirect to account page holdings tab to refresh list and close drawer
    redirect_to account_path(@holding.account, tab: "holdings")
  end

  def unlock_cost_basis
    @holding.unlock_cost_basis!
    flash[:notice] = t(".success")

    # Redirect to account page holdings tab to refresh list and close drawer
    redirect_to account_path(@holding.account, tab: "holdings")
  end

  def destroy
    if @holding.account.can_delete_holdings?
      @holding.destroy_holding_and_entries!
      flash[:notice] = t(".success")
    else
      flash[:alert] = "You cannot delete this holding"
    end

    respond_to do |format|
      format.html { redirect_back_or_to account_path(@holding.account) }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, account_path(@holding.account)) }
    end
  end

  def remap_security
    # Combobox returns "TICKER|EXCHANGE" format
    ticker, exchange = params[:security_id].to_s.split("|")

    # Validate ticker is present (form has required: true, but can be bypassed)
    if ticker.blank?
      flash[:alert] = t(".security_not_found")
      redirect_to account_path(@holding.account, tab: "holdings")
      return
    end

    new_security = Security::Resolver.new(
      ticker,
      exchange_operating_mic: exchange,
      country_code: Current.family.country
    ).resolve

    if new_security.nil?
      flash[:alert] = t(".security_not_found")
      redirect_to account_path(@holding.account, tab: "holdings")
      return
    end

    @holding.remap_security!(new_security)
    flash[:notice] = t(".success")

    respond_to do |format|
      format.html { redirect_to account_path(@holding.account, tab: "holdings") }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, account_path(@holding.account, tab: "holdings")) }
    end
  end

  def reset_security
    @holding.reset_security_to_provider!
    flash[:notice] = t(".success")

    respond_to do |format|
      format.html { redirect_to account_path(@holding.account, tab: "holdings") }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, account_path(@holding.account, tab: "holdings")) }
    end
  end

  private
    def set_holding
      @holding = Current.family.holdings.find(params[:id])
    end

    def holding_params
      params.require(:holding).permit(:cost_basis)
    end
end
