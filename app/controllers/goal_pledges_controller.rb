class GoalPledgesController < ApplicationController
  before_action :set_goal
  before_action :set_pledge, only: %i[extend destroy]
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def new
    account = preselected_account
    @pledge = @goal.goal_pledges.new(
      currency: @goal.currency,
      account: account,
      kind: kind_for_account(account),
      amount: params[:amount].presence
    )
  end

  def create
    @pledge = @goal.goal_pledges.new(pledge_params)
    @pledge.account = lookup_account(params.dig(:goal_pledge, :account_id))
    @pledge.kind = kind_for_account(@pledge.account)
    @pledge.currency = @goal.currency

    if @pledge.save
      flash[:notice] = t(".success")
      respond_to do |format|
        format.html { redirect_to goal_path(@goal) }
        format.turbo_stream do
          render turbo_stream: turbo_stream.action(:redirect, goal_path(@goal))
        end
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def extend
    @pledge.extend!
    redirect_to goal_path(@goal), notice: t(".success")
  rescue GoalPledge::NotOpenError
    redirect_to goal_path(@goal), alert: t(".not_open")
  end

  def destroy
    @pledge.cancel!
    redirect_to goal_path(@goal), notice: t(".success")
  rescue GoalPledge::NotOpenError
    redirect_to goal_path(@goal), alert: t(".not_open")
  end

  private
    def set_goal
      @goal = Current.family.goals.find(params[:goal_id])
    end

    def set_pledge
      @pledge = @goal.goal_pledges.find(params[:id])
    end

    def pledge_params
      params.require(:goal_pledge).permit(:amount)
    end

    def lookup_account(id)
      return nil if id.blank?
      @goal.linked_accounts.find_by(id: id)
    end

    def preselected_account
      requested = params[:account_id].presence && @goal.linked_accounts.find_by(id: params[:account_id])
      requested || @goal.linked_accounts.first
    end

    # Per-account: manual accounts get a `manual_save` pledge (resolves on the
    # user's next valuation), connected accounts get a `transfer` pledge
    # (resolves when the synced deposit posts). Account-level avoids the
    # mixed-funding goal bug where the goal-level toggle picked one kind for
    # all pledges regardless of which account the user actually moved money
    # into.
    def kind_for_account(account)
      return "transfer" if account.nil?
      account.manual? ? "manual_save" : "transfer"
    end

    def record_not_found
      redirect_to goals_path, alert: t("goals.errors.not_found")
    end
end
