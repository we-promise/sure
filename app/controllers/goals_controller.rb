class GoalsController < ApplicationController
  before_action :set_goal, only: %i[show edit update destroy]

  def index
    @goals = Current.family.goals.by_priority
  end

  def show
  end

  def new
    @goal = Current.family.goals.build(currency: Current.family.currency, goal_type: "custom")
  end

  def create
    @goal = Current.family.goals.build(goal_params)

    if @goal.save
      redirect_to goal_path(@goal), notice: t("goals.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @goal.update(goal_params)
      redirect_to goal_path(@goal), notice: t("goals.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @goal.destroy!
    redirect_to goals_path, notice: t("goals.deleted")
  end

  private

    def set_goal
      @goal = Current.family.goals.find(params[:id])
    end

    def goal_params
      params.require(:goal).permit(
        :name, :description, :goal_type, :target_amount, :current_amount,
        :target_date, :lucide_icon, :color, :priority, :is_completed, :currency
      )
    end
end
