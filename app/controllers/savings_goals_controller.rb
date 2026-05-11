class SavingsGoalsController < ApplicationController
  before_action :set_savings_goal, only: %i[show edit update destroy pause resume complete archive unarchive]

  STATE_FILTERS = %w[all active paused completed archived].freeze

  def index
    @state_filter = STATE_FILTERS.include?(params[:state]) ? params[:state] : "active"
    scope = Current.family.savings_goals.with_current_balance.alphabetically
    scope = scope.where(state: @state_filter) unless @state_filter == "all"
    @savings_goals = scope.to_a

    @counts = STATE_FILTERS.each_with_object({}) do |state, h|
      h[state] = state == "all" ? Current.family.savings_goals.count : Current.family.savings_goals.where(state: state).count
    end

    @linkable_account_count = Current.family.accounts.where(accountable_type: "Depository").visible.count
  end

  def show
    @contributions = @savings_goal.savings_contributions.includes(:account).chronological.limit(50)
    @funding_breakdown = funding_breakdown_for(@savings_goal)
  end

  def new
    @savings_goal = Current.family.savings_goals.new(
      color: SavingsGoal::COLORS.sample,
      currency: Current.family.primary_currency_code
    )
    @linkable_accounts = linkable_accounts_for_new
  end

  def create
    @savings_goal = Current.family.savings_goals.new(savings_goal_params)
    accounts = lookup_accounts(params.dig(:savings_goal, :account_ids))
    @savings_goal.currency = accounts.first.currency if accounts.any? && @savings_goal.currency.blank?

    SavingsGoal.transaction do
      accounts.each { |a| @savings_goal.savings_goal_accounts.build(account: a) }
      @savings_goal.save!
      create_initial_contribution_if_provided!(@savings_goal, accounts)
    end

    flash[:notice] = t(".success")
    respond_to do |format|
      format.html { redirect_to savings_goal_path(@savings_goal) }
      format.turbo_stream do
        render turbo_stream: turbo_stream.action(:redirect, savings_goal_path(@savings_goal))
      end
    end
  rescue ActiveRecord::RecordInvalid
    @linkable_accounts = linkable_accounts_for_new
    render :new, status: :unprocessable_entity
  end

  def edit
  end

  def update
    if @savings_goal.update(savings_goal_update_params)
      flash[:notice] = t(".success")
      respond_to do |format|
        format.html { redirect_to savings_goal_path(@savings_goal) }
        format.turbo_stream do
          render turbo_stream: turbo_stream.action(:redirect, savings_goal_path(@savings_goal))
        end
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    unless @savings_goal.archived?
      redirect_to savings_goal_path(@savings_goal), alert: t(".archive_first")
      return
    end

    @savings_goal.destroy!
    redirect_to savings_goals_path, notice: t(".success")
  end

  def pause
    perform_transition!(:pause)
  end

  def resume
    perform_transition!(:resume)
  end

  def complete
    perform_transition!(:complete)
  end

  def archive
    perform_transition!(:archive)
  end

  def unarchive
    perform_transition!(:unarchive)
  end

  private
    def set_savings_goal
      @savings_goal = Current.family.savings_goals.find(params[:id])
    end

    def savings_goal_params
      params.require(:savings_goal).permit(:name, :target_amount, :target_date, :color, :notes)
    end

    def savings_goal_update_params
      params.require(:savings_goal).permit(:name, :target_amount, :target_date, :color, :notes)
    end

    def lookup_accounts(ids)
      return [] if ids.blank?

      ids = Array(ids).reject(&:blank?)
      Current.family.accounts.where(accountable_type: "Depository").visible.where(id: ids).to_a
    end

    def linkable_accounts_for_new
      Current.family.accounts.where(accountable_type: "Depository").visible.alphabetically.to_a
    end

    def create_initial_contribution_if_provided!(goal, accounts)
      amount = params.dig(:savings_goal, :initial_contribution_amount)
      account_id = params.dig(:savings_goal, :initial_contribution_account_id)
      return if amount.blank? || account_id.blank?
      return unless BigDecimal(amount.to_s) > 0

      source = accounts.find { |a| a.id == account_id }
      raise ActiveRecord::RecordInvalid.new(goal) unless source

      goal.savings_contributions.create!(
        account: source,
        amount: amount,
        currency: goal.currency,
        source: "initial",
        contributed_at: Date.current
      )
    end

    def funding_breakdown_for(goal)
      totals = goal.savings_contributions
                   .group(:account_id)
                   .sum(:amount)
      goal.linked_accounts.map do |account|
        amount = totals[account.id] || 0
        { account: account, amount: amount, money: Money.new(amount, goal.currency) }
      end
    end

    def perform_transition!(event)
      if @savings_goal.aasm.may_fire_event?(event)
        @savings_goal.public_send("#{event}!")
        respond_to do |format|
          format.html { redirect_to savings_goal_path(@savings_goal), notice: t(".success") }
          format.turbo_stream do
            render turbo_stream: turbo_stream.action(:redirect, savings_goal_path(@savings_goal))
          end
        end
      else
        redirect_to savings_goal_path(@savings_goal), alert: t(".invalid_transition")
      end
    end
end
