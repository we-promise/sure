class BudgetPlansController < ApplicationController
  before_action :set_budget_plan, only: %i[edit update destroy]

  def new
    @budget_plan = Current.family.budget_plans.new
    @selectable_accounts = selectable_accounts
  end

  def create
    @budget_plan = Current.family.budget_plans.new(budget_plan_params)
    accounts = lookup_accounts(params.dig(:budget_plan, :account_ids))

    BudgetPlan.transaction do
      accounts.each { |account| @budget_plan.budget_plan_accounts.build(account: account) }
      @budget_plan.save!
    end

    redirect_to_plan_budget(@budget_plan, notice: t(".success"))
  rescue ActiveRecord::RecordInvalid
    @selectable_accounts = selectable_accounts
    render :new, status: :unprocessable_entity
  end

  def edit
    @selectable_accounts = selectable_accounts
    @scoped_account_ids = @budget_plan.budget_plan_accounts.pluck(:account_id).map(&:to_s)
  end

  def update
    account_ids = params.dig(:budget_plan, :account_ids)
    accounts_supplied = !account_ids.nil?
    accounts = accounts_supplied ? lookup_accounts(account_ids) : []

    BudgetPlan.transaction do
      @budget_plan.update!(budget_plan_params)
      sync_scoped_accounts!(@budget_plan, accounts) if accounts_supplied
    end

    redirect_to_plan_budget(@budget_plan, notice: t(".success"))
  rescue ActiveRecord::RecordInvalid
    @selectable_accounts = selectable_accounts
    @scoped_account_ids = @budget_plan.budget_plan_accounts.pluck(:account_id).map(&:to_s)
    render :edit, status: :unprocessable_entity
  end

  def destroy
    if @budget_plan.is_default?
      redirect_to budgets_path, alert: t(".cannot_delete_default")
      return
    end

    @budget_plan.destroy!
    redirect_to budgets_path, notice: t(".success")
  end

  private
    def set_budget_plan
      @budget_plan = Current.family.budget_plans.find(params[:id])
    end

    def budget_plan_params
      params.require(:budget_plan).permit(:name)
    end

    def redirect_to_plan_budget(plan, notice:)
      budget = Budget.find_or_bootstrap(Current.family, start_date: Date.current, user: Current.user, plan: plan)
      target = budget ? budget_path(budget) : budgets_path

      flash[:notice] = notice
      respond_to do |format|
        format.html { redirect_to target }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, target) }
      end
    end

    # Submitted ids are re-scoped through the user's accessible accounts —
    # never trusted raw. Unknown ids simply drop out of the checkbox set.
    def lookup_accounts(ids)
      return [] if ids.blank?

      ids = Array(ids).reject(&:blank?)
      Current.user.accessible_accounts.visible.where(id: ids).to_a
    end

    def selectable_accounts
      Current.user.accessible_accounts.visible.alphabetically.to_a
    end

    # Goals-style sync: only unlink accounts the current user can see in the
    # picker. Another member's private account never renders as a checkbox,
    # so its absence from the submitted set is not an intentional removal.
    def sync_scoped_accounts!(plan, accounts)
      desired_ids = accounts.map(&:id).to_set
      current_ids = plan.budget_plan_accounts.pluck(:account_id).to_set
      removable_ids = Current.user.accessible_accounts.where(id: current_ids.to_a).pluck(:id).to_set

      plan.budget_plan_accounts.where(account_id: ((current_ids & removable_ids) - desired_ids).to_a).destroy_all
      plan.budget_plan_accounts.reload

      (desired_ids - current_ids).each do |account_id|
        plan.budget_plan_accounts.create!(account_id: account_id)
      end
    end
end
