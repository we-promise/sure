class GoalPledgesController < ApplicationController
  before_action :set_goal
  before_action :set_pledge, only: %i[extend destroy]
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def new
    @pledge = @goal.goal_pledges.new(
      currency: @goal.currency,
      kind: default_kind_for(@goal),
      amount: params[:amount].presence
    )
  end

  def create
    @pledge = @goal.goal_pledges.new(pledge_params)
    @pledge.kind = default_kind_for(@goal) if @pledge.kind.blank?
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
  rescue ActiveRecord::RecordInvalid
    redirect_to goal_path(@goal), alert: t(".not_open")
  end

  def destroy
    @pledge.cancel!
    redirect_to goal_path(@goal), notice: t(".success")
  rescue ActiveRecord::RecordInvalid
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
      params.require(:goal_pledge).permit(:amount, :account_id, :kind)
    end

    def default_kind_for(goal)
      goal.any_connected_account? ? "transfer" : "manual_save"
    end

    def record_not_found
      redirect_to goals_path, alert: t("goals.errors.not_found")
    end
end
