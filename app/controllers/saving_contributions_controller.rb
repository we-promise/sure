class SavingContributionsController < ApplicationController
  before_action :set_saving_goal
  before_action :set_contribution, only: [ :destroy ]

  def new
    @contribution = @saving_goal.saving_contributions.new
    @budget = Budget.find_by(id: params[:budget_id], family: Current.family) if params[:budget_id]

    if @saving_goal.monthly_target
      suggested = @saving_goal.monthly_target
      # Cap by available surplus if in budget context
      if @budget && suggested > @budget.available_for_goals
        suggested = @budget.available_for_goals
      end
      @contribution.amount = [ suggested, 0 ].max
    end
  end

  def create
    @contribution = @saving_goal.saving_contributions.new(contribution_params)
    @contribution.currency = @saving_goal.currency

    # Set budget context if provided
    if params[:saving_contribution][:budget_id].present?
      @budget = Budget.find_by(id: params[:saving_contribution][:budget_id], family: Current.family)
    end

    if @budget
      @budget.with_lock do
        @contribution.month = @budget.start_date.beginning_of_month

        # Validate against available surplus
        if @contribution.amount > @budget.available_for_goals
          @contribution.errors.add(:amount, I18n.t("saving_contributions.errors.exceeds_surplus"))
          render :new, status: :unprocessable_entity
          return
        end

        if @contribution.save
          redirect_to budget_path(@budget), notice: t(".success")
        else
          render :new, status: :unprocessable_entity
          raise ActiveRecord::Rollback
        end
      end
    else
      @contribution.month = Date.current.beginning_of_month

      if @contribution.save
        redirect_to saving_goal_path(@saving_goal), notice: t(".success")
      else
        render :new, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @contribution.destroy
    redirect_to saving_goal_path(@saving_goal), notice: t(".removed")
  end

  private

    def set_saving_goal
      @saving_goal = Current.family.saving_goals.find(params[:saving_goal_id])
    end

    def set_contribution
      @contribution = @saving_goal.saving_contributions.find(params[:id])
    end

    def contribution_params
      params.require(:saving_contribution).permit(:amount, :source, :budget_id)
    end
end
