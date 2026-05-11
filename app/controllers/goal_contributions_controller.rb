class GoalContributionsController < ApplicationController
  before_action :set_goal
  before_action :set_contribution, only: :destroy
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found

  def new
    @contribution = @goal.goal_contributions.new(
      contributed_at: Date.current,
      currency: @goal.currency,
      source: "manual",
      amount: params[:amount].presence
    )
  end

  def create
    @contribution = @goal.goal_contributions.new(contribution_params.merge(source: "manual"))
    @contribution.account = lookup_account(params.dig(:goal_contribution, :account_id))
    @contribution.currency = @goal.currency

    if @contribution.save
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

  def destroy
    if @contribution.initial?
      redirect_to goal_path(@goal), alert: t(".initial_not_deletable")
      return
    end

    @contribution.destroy!
    redirect_to goal_path(@goal), notice: t(".success")
  end

  private
    def set_goal
      @goal = Current.family.goals.find(params[:goal_id])
    end

    def set_contribution
      @contribution = @goal.goal_contributions.find(params[:id])
    end

    def contribution_params
      params.require(:goal_contribution).permit(:amount, :contributed_at, :notes)
    end

    def lookup_account(id)
      return nil if id.blank?
      @goal.linked_accounts.find_by(id: id)
    end

    def record_not_found
      redirect_to goals_path, alert: t("goals.errors.not_found")
    end
end
