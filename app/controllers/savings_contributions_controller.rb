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
      flash[:notice] = t("savings_contributions.create.success")
      respond_to do |format|
        format.html { redirect_to savings_goal_path(@savings_goal) }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, savings_goal_path(@savings_goal)) }
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @contribution.destroy
    redirect_to savings_goal_path(@savings_goal), notice: t("savings_contributions.destroy.success")
  end

private
  def set_breadcrumbs
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("savings_goals.index.title"), savings_goals_path ],
      [ @savings_goal.name, savings_goal_path(@savings_goal) ],
      [ t("savings_goals.show.contributions.add"), nil ]
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
  # contribution attempts on the same family serialize cleanly. The key
  # comes from SavingsGoal.advisory_lock_key_for so manual contributions
  # and AutoFundJob mutually exclude on the same family -- a separate
  # key here would let an auto-fund insert race a manual contribution
  # off a stale `remaining_amount` snapshot and overfund the goal.
  def save_with_advisory_lock(contribution)
    key = SavingsGoal.advisory_lock_key_for(Current.family.id)
    saved = false
    Family.transaction do
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?)", key ])
      )
      saved = contribution.save
    end
    saved
  end
end
