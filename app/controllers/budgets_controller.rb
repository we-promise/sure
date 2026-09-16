class BudgetsController < ApplicationController
  include BudgetOwnership

  before_action :set_budget, only: %i[show edit update copy_previous]
  before_action :ensure_budget_editable!, only: %i[edit update copy_previous]

  def index
    redirect_to_current_month_budget
  end

  def show
    @source_budget = @budget.most_recent_initialized_budget unless @budget.initialized?
    @editable = @budget.editable_by?(Current.user)
    @switch_options = budget_switch_options(@budget)
    @breadcrumbs = plan_breadcrumb_prefix + [ [ t("breadcrumbs.budgets"), nil ] ]
  end

  def edit
    render layout: "wizard"
  end

  def update
    @budget.update!(budget_params)
    redirect_to budget_budget_categories_path(@budget, **budget_owner_query)
  end

  def copy_previous
    if @budget.initialized?
      redirect_to budget_path(@budget, **budget_owner_query), alert: t("budgets.copy_previous.already_initialized")
      return
    end

    source_budget = @budget.most_recent_initialized_budget

    if source_budget
      @budget.copy_from!(source_budget)
      redirect_to budget_budget_categories_path(@budget, **budget_owner_query), notice: t("budgets.copy_previous.success", source_name: source_budget.name)
    else
      redirect_to budget_path(@budget, **budget_owner_query), alert: t("budgets.copy_previous.no_source")
    end
  end

  def picker
    render partial: "budgets/picker", locals: {
      family: Current.family,
      year: params[:year].to_i || Date.current.year
    }
  end

  private

    def budget_create_params
      params.require(:budget).permit(:start_date)
    end

    def budget_params
      params.require(:budget).permit(:budgeted_spending, :expected_income)
    end

    def set_budget
      start_date = Budget.param_to_date(params[:month_year], family: Current.family)
      @budget = resolve_budget(start_date)
      raise ActiveRecord::RecordNotFound unless @budget
    end

    def redirect_to_current_month_budget
      current_budget = resolve_budget(Date.current)
      redirect_to budget_path(current_budget, **budget_owner_query)
    end
end
