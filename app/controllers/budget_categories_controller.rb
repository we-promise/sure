class BudgetCategoriesController < ApplicationController
  before_action :set_budget

  def index
    @budget_categories = @budget.budget_categories.includes(:category)
    render layout: "wizard"
  end

  def show
    @recent_transactions = @budget.transactions

    if params[:id] == BudgetCategory.uncategorized.id
      @budget_category = @budget.uncategorized_budget_category
      @recent_transactions = @recent_transactions.where(transactions: { category_id: nil })
    else
      @budget_category = Current.family.budget_categories.find(params[:id])
      @recent_transactions = @recent_transactions.joins("LEFT JOIN categories ON categories.id = transactions.category_id")
                                                 .where("categories.id = ? OR categories.parent_id = ?", @budget_category.category.id, @budget_category.category.id)
    end

    @recent_transactions = @recent_transactions.order("entries.date DESC, ABS(entries.amount) DESC").take(3)
  end

  def update
    @budget_category = Current.family.budget_categories.find(params[:id])

    BudgetCategory.transaction do
      previous_budgeted_spending = @budget_category.budgeted_spending || 0
      @budget_category.update!(budget_category_params)
      update_parent_budget!(previous_budgeted_spending)
    end

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_budget_categories_path(@budget) }
    end
  rescue ActiveRecord::RecordInvalid
    render :index, status: :unprocessable_entity
  end

  private
    def update_parent_budget!(previous_budgeted_spending)
      return unless @budget_category.subcategory?

      parent_budget_category = @budget_category.parent_budget_category
      return unless parent_budget_category

      current_budgeted_spending = @budget_category.budgeted_spending || 0
      delta = current_budgeted_spending - previous_budgeted_spending
      return if delta.zero?

      parent_budget_category.update!(
        budgeted_spending: non_negative_budget((parent_budget_category.budgeted_spending || 0) + delta)
      )
    end

    def non_negative_budget(amount)
      [ amount, 0 ].max
    end

    def budget_category_params
      params.require(:budget_category).permit(:budgeted_spending).tap do |params|
        params[:budgeted_spending] = params[:budgeted_spending].presence || 0
      end
    end

    def set_budget
      start_date = Budget.param_to_date(params[:budget_month_year], family: Current.family)
      @budget = Current.family.budgets.find_by(start_date: start_date)
    end
end
