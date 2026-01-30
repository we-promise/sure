class SavingGoalsController < ApplicationController
  before_action :set_saving_goal, only: [ :show, :edit, :update, :destroy, :pause, :resume, :complete, :archive ]

  def index
    @saving_goals = Current.family.saving_goals.order(created_at: :desc)

    if params[:status].present? && params[:status] != "all"
      @saving_goals = @saving_goals.where(status: params[:status])
    elsif params[:status] == "all"
      # No filter
    else
      @saving_goals = @saving_goals.active
    end
  end

  def show
  end

  def new
    @saving_goal = Current.family.saving_goals.new
  end

  def create
    @saving_goal = Current.family.saving_goals.new(saving_goal_params.except(:initial_amount))
    @saving_goal.currency = Current.family.currency

    if saving_goal_params[:initial_amount].present? && saving_goal_params[:initial_amount].to_d > 0
      @saving_goal.saving_contributions.build(
        amount: saving_goal_params[:initial_amount],
        currency: @saving_goal.currency,
        month: Date.current.beginning_of_month,
        source: :initial_balance
      )
    end

    if @saving_goal.save
      redirect_to saving_goals_path, notice: t(".success")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @saving_goal.update(saving_goal_params)
      redirect_to saving_goals_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @saving_goal.destroy
    redirect_to saving_goals_path, notice: t(".success")
  end

  def pause
    @saving_goal.pause!
    redirect_to saving_goal_path(@saving_goal), notice: t(".success")
  rescue SavingGoal::InvalidTransitionError => e
    redirect_to saving_goal_path(@saving_goal), alert: e.message
  end

  def resume
    @saving_goal.resume!
    redirect_to saving_goal_path(@saving_goal), notice: t(".success")
  rescue SavingGoal::InvalidTransitionError => e
    redirect_to saving_goal_path(@saving_goal), alert: e.message
  end

  def complete
    @saving_goal.complete!
    redirect_to saving_goal_path(@saving_goal), notice: t(".success")
  rescue SavingGoal::InvalidTransitionError => e
    redirect_to saving_goal_path(@saving_goal), alert: e.message
  end

  def archive
    @saving_goal.archive!
    redirect_to saving_goals_path, notice: t(".success")
  rescue SavingGoal::InvalidTransitionError => e
    redirect_to saving_goal_path(@saving_goal), alert: e.message
  end

  private

    def set_saving_goal
      @saving_goal = Current.family.saving_goals.find(params[:id])
    end

    def saving_goal_params
      params.require(:saving_goal).permit(:name, :target_amount, :target_date, :priority, :color, :icon, :notes, :initial_amount)
    end
end
