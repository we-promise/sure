class SavingsGoalsController < ApplicationController
  before_action :set_savings_goal, only: %i[show edit update destroy pause resume complete archive unarchive]

  def index
    state = params[:state].presence_in(%w[active paused completed archived all]) || "active"
    scope = Current.family.savings_goals.alphabetically
    @savings_goals = state == "all" ? scope : scope.where(state: state)
    @state = state
  end

  def show
  end

  def new
    @savings_goal = Current.family.savings_goals.new(state: "active")
    render layout: "wizard"
  end

  def create
    @savings_goal = Current.family.savings_goals.new(savings_goal_params)
    @savings_goal.account = lookup_account(savings_goal_params[:account_id])

    if @savings_goal.save
      handle_initial_contribution(@savings_goal)
      redirect_to savings_goal_path(@savings_goal), notice: "Savings goal created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if savings_goal_params[:account_id].present?
      @savings_goal.account = lookup_account(savings_goal_params[:account_id])
    end

    if @savings_goal.update(savings_goal_params)
      redirect_to savings_goal_path(@savings_goal), notice: "Savings goal updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @savings_goal.destroy
    redirect_to savings_goals_path, notice: "Savings goal deleted."
  end

  def pause
    transition!(:pause!, "Goal paused.")
  end

  def resume
    transition!(:resume!, "Goal resumed.")
  end

  def complete
    transition!(:complete!, "Goal marked as completed.")
  end

  def archive
    transition!(:archive!, "Goal archived.")
  end

  def unarchive
    transition!(:unarchive!, "Goal restored to active.")
  end

  private
    def set_savings_goal
      @savings_goal = Current.family.savings_goals.find(params[:id])
    end

    def savings_goal_params
      params.require(:savings_goal).permit(
        :account_id, :name, :target_amount, :target_date, :color, :icon, :notes
      )
    end

    # Scopes the lookup so a foreign account_id never silently associates.
    def lookup_account(account_id)
      return nil if account_id.blank?
      Current.family.accounts.find_by(id: account_id)
    end

    def handle_initial_contribution(goal)
      amount = params.dig(:savings_goal, :initial_contribution).to_d
      return unless amount.positive?
      goal.savings_contributions.create!(
        amount: amount,
        source: "initial",
        contributed_at: Date.current
      )
    end

    def transition!(event, message)
      @savings_goal.public_send(event)
      redirect_to savings_goal_path(@savings_goal), notice: message
    rescue AASM::InvalidTransition => e
      redirect_to savings_goal_path(@savings_goal), alert: e.message
    end
end
