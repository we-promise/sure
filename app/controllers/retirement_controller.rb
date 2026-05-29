class RetirementController < ApplicationController
  include RetirementScoped

  def show
    @glide = @plan.glide_payload
    @baseline = Current.family.retirement_spending_baseline(user: Current.user)
    @pension_sources = @plan.pension_sources.order(:start_age)
    @adjustments = @plan.adjustments.ordered
    @statements = @plan.statements.chronological.reverse
    @bucket_account_ids = @plan.retirement_bucket_entries.pluck(:account_id).to_set
    @bucket_candidates = Current.family.accounts.visible.accessible_by(Current.user).alphabetically
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.retirement"), nil ]
    ]
  end

  def update
    if @plan.update(retirement_params: merged_plan_params)
      redirect_to retirement_path, notice: t(".updated")
    else
      redirect_to retirement_path, alert: @plan.errors.full_messages.to_sentence
    end
  end

  # Live what-if: recompute against transient inputs WITHOUT persisting, and
  # stream the KPI cards back. The plan is only saved via #update.
  def forecast
    @plan.assign_attributes(retirement_params: merged_plan_params)
    render turbo_stream: turbo_stream.replace(
      "retirement_kpis", partial: "retirement/kpis", locals: { plan: @plan }
    )
  end

  private
    def merged_plan_params
      raw = params.fetch(:retirement, {}).permit(
        :birth_year, :retire_age, :target_spend, :monthly_savings, :real_return_pct
      ).to_h
      (@plan.retirement_params || {}).merge(raw.reject { |_, v| v.to_s.strip.empty? })
    end
end
