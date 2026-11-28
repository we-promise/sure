class RetirementPlansController < ApplicationController
  before_action :require_preview_features!
  before_action :set_retirement_plan

  # One reference date for every figure on the page.
  def show
    @as_of = Date.current

    if @retirement_plan.mode == "fire"
      @solution = @retirement_plan.solve(as_of: @as_of)
      @simulation = @solution&.retirement_year && @retirement_plan.simulation(as_of: @as_of, retirement_year: @solution.retirement_year)
    else
      @simulation = @retirement_plan.simulation(as_of: @as_of)
    end

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.plan"), plan_path ], [ t("breadcrumbs.retirement_plan"), nil ] ]
    @milestones = @simulation ? @retirement_plan.milestones(as_of: @as_of, simulation: @simulation) : []
    # Left out of the figures for want of an exchange rate: an expense left
    # out makes the plan look better than it is, so the page says so.
    @unconverted = {
      streams: @retirement_plan.unconverted_stream_count(as_of: @as_of),
      accounts: @retirement_plan.unconverted_account_count(as_of: @as_of)
    }.select { |_, count| count.positive? }
  end

  def edit
  end

  # Saved from the modal: a refusal re-renders the form inside it, and a
  # save sends the page that opened it back to itself.
  def update
    if save_settings
      respond_to do |format|
        format.html { redirect_back_or_to retirement_plan_path, notice: t(".success") }
        format.turbo_stream do
          flash[:notice] = t(".success")
          render turbo_stream: turbo_stream.action(:redirect, request.referer || retirement_plan_path)
        end
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    # Always the signed-in user's own plan: there is no id to tamper with, and
    # `user_id` is not a permitted parameter.
    def set_retirement_plan
      @retirement_plan = RetirementPlan.for(Current.user)
    end

    # Seeded after a save, never on a page view, and only the first time. The
    # settings and the seeding commit together, so a failure part-way leaves
    # neither behind. Two first saves at once race on the one-plan-per-user
    # index; the one that loses saves onto the plan the other created.
    def save_settings
      RetirementPlan.transaction do
        @retirement_plan.update(retirement_plan_params) || raise(ActiveRecord::Rollback)
        @retirement_plan.seed_streams!(as_of: Date.current)
        true
      end
    rescue ActiveRecord::RecordNotUnique
      raise unless @retirement_plan.new_record?

      @retirement_plan = RetirementPlan.find_by!(user: Current.user)
      retry
    end

    def retirement_plan_params
      params.require(:retirement_plan).permit(
        :safe_withdrawal_rate_percent, :expected_annual_return_percent, :savings_rate_percent, :retirement_date,
        :birth_year, :end_age, :inflation_rate_percent, :mode
      )
    end
end
