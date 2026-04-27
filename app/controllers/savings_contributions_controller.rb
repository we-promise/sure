class SavingsContributionsController < ApplicationController
  before_action :set_savings_goal
  before_action :set_contribution, only: :destroy
  before_action :set_breadcrumbs


  def new
    @contribution = @savings_goal.savings_contributions.new(contributed_at: Date.current)
  end

  def create
    @contribution = @savings_goal.savings_contributions.new(contribution_params)
    @contribution.source = "manual"
    @contribution.contributed_at ||= Date.current

    if save_with_advisory_lock(@contribution)
      redirect_to savings_goal_path(@savings_goal), notice: "Contribution added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @contribution.destroy
    redirect_to savings_goal_path(@savings_goal), notice: "Contribution removed."
  end

private
  def set_breadcrumbs
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Savings goals", savings_goals_path ],
      [ @savings_goal.name, savings_goal_path(@savings_goal) ],
      [ "Add contribution", nil ]
    ]
  end

  def set_savings_goal
    @savings_goal = Current.family.savings_goals.find(params[:savings_goal_id])
    end

  def set_contribution
    @contribution = @savings_goal.savings_contributions.find(params[:id])
  end

  def contribution_params
    params.require(:savings_contribution).permit(:amount, :notes, :contributed_at)
  end

  # Wraps the create in a Postgres advisory xact lock so concurrent
  # contribution attempts on the same family serialize cleanly. The
  # partial unique index on (savings_goal_id, budget_id) for source=auto
  # handles auto-vs-auto races at the DB level; this lock keeps manual
  # contributions tidy too.
  def save_with_advisory_lock(contribution)
    key = Digest::SHA1.hexdigest("savings_contribution:#{Current.family.id}").to_i(16) % (2**63)
    saved = false
    Family.transaction do
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{key})")
      saved = contribution.save
    end
    saved
  end
end
