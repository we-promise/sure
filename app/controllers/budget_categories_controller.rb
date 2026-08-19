class BudgetCategoriesController < ApplicationController
  include BudgetOwnership

  before_action :set_budget
  before_action :ensure_budget_editable!, only: %i[index update]

  def index
    @budget_categories = @budget.budget_categories.includes(:category)
    render layout: "wizard"
  end

  def show
    # The aggregate `Budget#actual_spending` already excludes transactions
    # whose kind is in BUDGET_EXCLUDED_KINDS (funds_movement, one_time,
    # cc_payment) via IncomeStatement. The drilldown list must apply the
    # same filter, otherwise a matched transfer (post-#874 the matcher
    # correctly tags inflow as funds_movement and outflow per destination
    # account) shows under the Uncategorized card -- or any retained
    # category -- even though the aggregate ignores it. See issue #1059.
    @recent_transactions = @budget.transactions
                                  .where.not(transactions: { kind: Transaction::BUDGET_EXCLUDED_KINDS })

    if params[:id] == BudgetCategory.uncategorized.id
      @budget_category = @budget.uncategorized_budget_category
      @recent_transactions = @recent_transactions.where(transactions: { category_id: nil })
    else
      @budget_category = @budget.budget_categories.find(params[:id])
      @recent_transactions = @recent_transactions.joins("LEFT JOIN categories ON categories.id = transactions.category_id")
                                                 .where("categories.id = ? OR categories.parent_id = ?", @budget_category.category.id, @budget_category.category.id)
    end

    @recent_transactions = @recent_transactions.order("entries.date DESC, ABS(entries.amount) DESC").take(3)
  end

  def update
    @budget_category = @budget.budget_categories.find(params[:id])
    @budget_category.update_budgeted_spending!(budgeted_spending_param)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_budget_categories_path(@budget, **budget_owner_query) }
    end
  rescue ActiveRecord::RecordInvalid
    render :index, status: :unprocessable_entity
  end

  private
    def budgeted_spending_param
      params.require(:budget_category)
        .permit(:budgeted_spending)
        .fetch(:budgeted_spending, nil)
        .presence || 0
    end

    def set_budget
      start_date = Budget.param_to_date(params[:budget_month_year], family: Current.family)
      @budget = resolve_budget(start_date)
      raise ActiveRecord::RecordNotFound unless @budget
    end
end
