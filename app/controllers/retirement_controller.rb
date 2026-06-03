class RetirementController < ApplicationController
  include RetirementScoped

  def show
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
end
