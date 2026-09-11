class BudgetCategoriesController < ApplicationController
  include BudgetOwnership

  before_action :set_budget
  before_action :ensure_budget_editable!, only: %i[index update move]

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
    unless rollover_enabled_param.nil?
      @budget_category.update!(rollover_enabled: rollover_enabled_param)
      # A month the user opened before making this choice was created with the
      # flag off and had nothing to inherit, so the chain stopped there.
      @budget_category.propagate_rollover_choice_forward!
    end
    @budget_category.update_budgeted_spending!(budgeted_spending_param)

    # Allocations and the rollover toggle both feed the chain, so recompute
    # it here rather than on every transaction change: the budget page is
    # the only place the amount is read, and it always comes through here or
    # through Budget.find_or_bootstrap.
    Budget::RolloverCalculator.new(family: @budget.family, user: @budget.user).recompute!
    @budget_category.reload

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_budget_categories_path(@budget, **budget_owner_query) }
    end
  rescue ActiveRecord::RecordInvalid
    render :index, status: :unprocessable_entity
  end

  # Shifts allocation from one envelope to another in one gesture. The
  # recompute deliberately runs AFTER move_allocation! has committed, never
  # inside it: the calculator takes an advisory lock, and taking it while the
  # move still holds its row locks would invert the lock order #update
  # already established and deadlock two concurrent moves. Once per move —
  # the calculator rereads the whole chain either way.
  def move
    @from = @budget.budget_categories.find(params[:from_id])
    @to = @budget.budget_categories.find(params[:to_id])

    BudgetCategory.move_allocation!(from: @from, to: @to, amount: move_amount_param)
    Budget::RolloverCalculator.new(family: @budget.family, user: @budget.user).recompute!

    @budget.reload
    flash.now[:notice] = t(".success")
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to budget_budget_categories_path(@budget, **budget_owner_query), notice: t(".success") }
    end
  rescue BudgetCategory::InvalidMove => e
    flash.now[:alert] = e.message
    respond_to do |format|
      format.turbo_stream { render turbo_stream: flash_notification_stream_items, status: :unprocessable_entity }
      format.html do
        @budget_categories = @budget.budget_categories.includes(:category)
        render :index, layout: "wizard", status: :unprocessable_entity
      end
    end
  end

  private
    # A blank or non-numeric amount is a zero move, which move_allocation!
    # refuses with the localized "enter an amount greater than zero".
    def move_amount_param
      params.require(:budget_category_move).permit(:amount).fetch(:amount, nil).to_d
    end

    def rollover_enabled_param
      permitted = params.require(:budget_category).permit(:rollover_enabled)
      return nil unless permitted.key?(:rollover_enabled)

      ActiveModel::Type::Boolean.new.cast(permitted[:rollover_enabled])
    end

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
