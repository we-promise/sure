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

  # A user's first stream also saves their plan. One transaction, so an invalid
  # stream leaves no empty plan behind.
  def create
    saved = RetirementPlan.transaction do
      @retirement_plan.save! if @retirement_plan.new_record?
      @stream = @retirement_plan.streams.new(stream_params.merge(source: "manual"))
      @stream.save || raise(ActiveRecord::Rollback)
    end

    if saved
      redirect_to retirement_plan_path, notice: t(".success")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @stream.update(stream_params)
      redirect_to retirement_plan_path, notice: t(".success")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @stream.destroy!
    redirect_to retirement_plan_path, notice: t(".success")
  end

  private
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
