class GoalsController < ApplicationController
  before_action :set_goal, only: %i[show edit update destroy pause resume complete archive unarchive]
  rescue_from ActiveRecord::RecordNotFound, with: :goal_not_found

  STATE_FILTERS = %w[all active paused completed archived].freeze
  ACTIVE_STATUS_RANK = { behind: 0, on_track: 1, no_target_date: 2 }.freeze

  def index
    state_counts = Current.family.goals.group(:state).count
    @counts = STATE_FILTERS.each_with_object({}) do |state, h|
      h[state] = state == "all" ? state_counts.values.sum : (state_counts[state] || 0)
    end

    all_goals = Current.family.goals.alphabetically.includes(:linked_accounts, :open_pledges).to_a
    @active_goals = all_goals.reject { |g| %w[completed archived].include?(g.state) }
                             .sort_by { |g| [ g.paused? ? 3 : ACTIVE_STATUS_RANK.fetch(g.status, 4), g.name.downcase ] }
    @completed_goals = all_goals.select { |g| g.state == "completed" }
    @archived_goals = all_goals.select { |g| g.state == "archived" }

    @linkable_account_count = Current.family.accounts.where(accountable_type: "Depository").visible.count
    @kpi = kpi_payload(@active_goals)
    @any_pending_pledge = @active_goals.any? { |g| g.open_pledges.any? }
    @show_search = @active_goals.size > 6
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("goals.index.title"), nil ]
    ]
  end

  def show
    @open_pledges = @goal.open_pledges.chronological.to_a
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("goals.index.title"), goals_path ],
      [ @goal.name, nil ]
    ]
  end

  def new
    @goal = Current.family.goals.new(
      color: Goal::COLORS.sample,
      currency: Current.family.primary_currency_code
    )
    @linkable_accounts = linkable_accounts_for_new
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("goals.index.title"), goals_path ],
      [ t("goals.new.heading"), nil ]
    ]
  end

  def create
    @goal = Current.family.goals.new(goal_params)
    accounts = lookup_accounts(params.dig(:goal, :account_ids))
    @goal.currency = accounts.first.currency if accounts.any? && @goal.currency.blank?

    Goal.transaction do
      accounts.each { |a| @goal.goal_accounts.build(account: a) }
      @goal.save!
    end

    flash[:notice] = t(".success")
    respond_to do |format|
      format.html { redirect_to goal_path(@goal) }
      format.turbo_stream do
        render turbo_stream: turbo_stream.action(:redirect, goal_path(@goal))
      end
    end
  rescue ActiveRecord::RecordInvalid
    @linkable_accounts = linkable_accounts_for_new
    render :new, status: :unprocessable_entity
  end

  def edit
    @linkable_accounts = linkable_accounts_for_new
    @currently_linked_account_ids = @goal.goal_accounts.pluck(:account_id).map(&:to_s)
  end

  def update
    account_ids = params.dig(:goal, :account_ids)
    accounts_supplied = !account_ids.nil?
    accounts = accounts_supplied ? lookup_accounts(account_ids) : []

    if accounts_supplied && accounts.empty?
      @goal.errors.add(:base, :at_least_one_linked_account_required)
      @linkable_accounts = linkable_accounts_for_new
      @currently_linked_account_ids = @goal.goal_accounts.pluck(:account_id).map(&:to_s)
      render :edit, status: :unprocessable_entity
      return
    end

    Goal.transaction do
      @goal.update!(goal_update_params)
      sync_linked_accounts!(@goal, accounts) if accounts_supplied
    end

    flash[:notice] = t(".success")
    respond_to do |format|
      format.html { redirect_to goal_path(@goal) }
      format.turbo_stream do
        render turbo_stream: turbo_stream.action(:redirect, goal_path(@goal))
      end
    end
  rescue ActiveRecord::RecordInvalid
    @linkable_accounts = linkable_accounts_for_new
    @currently_linked_account_ids = @goal.goal_accounts.pluck(:account_id).map(&:to_s)
    render :edit, status: :unprocessable_entity
  end

  def destroy
    unless @goal.archived?
      redirect_to goal_path(@goal), alert: t(".archive_first")
      return
    end

    @goal.destroy!
    redirect_to goals_path, notice: t(".success")
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
    def set_goal
      @goal = Current.family.goals
                             .includes(:linked_accounts, :open_pledges)
                             .find(params[:id])
    end

    def goal_not_found
      redirect_to goals_path, alert: t("goals.errors.not_found")
    end

    def goal_params
      params.require(:goal).permit(:name, :target_amount, :target_date, :color, :icon, :notes)
    end

    def goal_update_params
      params.require(:goal).permit(:name, :target_amount, :target_date, :color, :icon, :notes)
    end

    def lookup_accounts(ids)
      return [] if ids.blank?

      ids = Array(ids).reject(&:blank?)
      Current.family.accounts.where(accountable_type: "Depository").visible.where(id: ids).to_a
    end

    def linkable_accounts_for_new
      Current.family.accounts.where(accountable_type: "Depository").visible.alphabetically.to_a
    end

    def sync_linked_accounts!(goal, accounts)
      desired = accounts.map(&:id).to_set
      current = goal.goal_accounts.pluck(:account_id).to_set

      (current - desired).each do |id|
        goal.goal_accounts.where(account_id: id).destroy_all
      end
      (desired - current).each do |id|
        goal.goal_accounts.create!(account_id: id)
      end
    end

    def kpi_payload(active_goals)
      family = Current.family
      currency = family.primary_currency_code

      contributed_last_30d = family.savings_inflow_velocity(days: 30)
      needs = active_goals
        .select { |g| g.status == :behind }
        .sum { |g| g.monthly_target_amount.to_d }
      behind = active_goals.count { |g| g.status == :behind }
      on_track = active_goals.count { |g| g.status == :on_track || g.status == :reached }

      {
        currency: currency,
        contributed_last_30d_money: Money.new(contributed_last_30d, currency),
        needs_this_month_money: Money.new(needs, currency),
        on_track_count: on_track,
        behind_count: behind,
        active_total: active_goals.size
      }
    end

    def perform_transition!(event)
      if @goal.aasm.may_fire_event?(event)
        @goal.public_send("#{event}!")
        respond_to do |format|
          format.html { redirect_to goal_path(@goal), notice: t(".success") }
          format.turbo_stream do
            render turbo_stream: turbo_stream.action(:redirect, goal_path(@goal))
          end
        end
      else
        redirect_to goal_path(@goal), alert: t(".invalid_transition")
      end
    end
end
