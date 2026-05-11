class SavingsContributionsController < ApplicationController
  before_action :set_savings_goal
  before_action :set_contribution, only: :destroy

  def new
    @contribution = @savings_goal.savings_contributions.new(
      contributed_at: Date.current,
      currency: @savings_goal.currency,
      source: "manual"
    )
  end

  def create
    @contribution = @savings_goal.savings_contributions.new(contribution_params.merge(source: "manual"))
    @contribution.account = lookup_account(params.dig(:savings_contribution, :account_id))
    @contribution.currency = @savings_goal.currency

    if @contribution.save
      flash[:notice] = t(".success")
      respond_to do |format|
        format.html { redirect_to savings_goal_path(@savings_goal) }
        format.turbo_stream do
          render turbo_stream: turbo_stream.action(:redirect, savings_goal_path(@savings_goal))
        end
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    if @contribution.initial?
      redirect_to savings_goal_path(@savings_goal), alert: t(".initial_not_deletable")
      return
    end

    @contribution.destroy!
    redirect_to savings_goal_path(@savings_goal), notice: t(".success")
  end

  private
    def set_savings_goal
      @savings_goal = Current.family.savings_goals.find(params[:savings_goal_id])
    end

    def set_contribution
      @contribution = @savings_goal.savings_contributions.find(params[:id])
    end

    def contribution_params
      params.require(:savings_contribution).permit(:amount, :contributed_at, :notes)
    end

    def lookup_account(id)
      return nil if id.blank?
      @savings_goal.linked_accounts.find_by(id: id)
    end
end
