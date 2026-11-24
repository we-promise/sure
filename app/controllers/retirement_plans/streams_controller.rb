# The spending and income a user's retirement plan draws on. Always within
# the signed-in user's own plan: a stream id from anyone else's plan is not
# found.
class RetirementPlans::StreamsController < ApplicationController
  before_action :require_preview_features!
  before_action :set_retirement_plan
  before_action :set_stream, only: %i[edit update destroy]

  def new
    @stream = @retirement_plan.streams.new(kind: "expense", indexed: true)
  end

  def create
    if save_new_stream
      saved
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @stream.update(stream_params)
      saved
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @stream.destroy!
    redirect_to retirement_plan_path, notice: t(".success")
  end

  private
    # Saved from the modal: a refusal re-renders the form inside it, and a
    # save sends the planner back to itself.
    def saved
      respond_to do |format|
        format.html { redirect_to retirement_plan_path, notice: t(".success") }
        format.turbo_stream do
          flash[:notice] = t(".success")
          render turbo_stream: turbo_stream.action(:redirect, retirement_plan_path)
        end
      end
    end

    # A user's first stream also saves their plan. One transaction, so an
    # invalid stream leaves no empty plan behind. Two first saves at once
    # race on the one-plan-per-user index; the one that loses adds its
    # stream to the plan the other created.
    def save_new_stream
      RetirementPlan.transaction do
        @retirement_plan.save! if @retirement_plan.new_record?
        @stream = @retirement_plan.streams.new(stream_params.merge(source: "manual"))
        @stream.save || raise(ActiveRecord::Rollback)
      end
    rescue ActiveRecord::RecordNotUnique
      raise unless @retirement_plan.new_record?

      @retirement_plan = RetirementPlan.find_by!(user: Current.user)
      retry
    end

    def set_retirement_plan
      @retirement_plan = RetirementPlan.for(Current.user)
    end

    def set_stream
      @stream = @retirement_plan.streams.find(params[:id])
    end

    def stream_params
      params.require(:retirement_plan_stream).permit(:kind, :name, :annual_amount, :start_year, :end_year, :indexed)
    end
end
