class GoalsController < ApplicationController
  before_action :require_beta_features!
  before_action :set_goal, only: %i[show edit update destroy pause resume complete archive unarchive]
  rescue_from ActiveRecord::RecordNotFound, with: :goal_not_found

  STATE_FILTERS = %w[all active paused completed archived].freeze
  ACTIVE_STATUS_RANK = { behind: 0, on_track: 1, no_target_date: 2 }.freeze

  def index
    state_counts = Current.family.goals.group(:state).count
    @counts = STATE_FILTERS.each_with_object({}) do |state, h|
      h[state] = state == "all" ? state_counts.values.sum : (state_counts[state] || 0)
    end

    all_goals = Current.family.goals
                       .alphabetically
                       .includes(:open_pledges, linked_accounts: :account_providers)
                       .to_a
    @active_goals = all_goals.reject { |g| %w[completed archived].include?(g.state) }
                             .sort_by { |g| [ g.paused? ? 3 : ACTIVE_STATUS_RANK.fetch(g.status, 4), g.name.downcase ] }
    @completed_goals = all_goals.select { |g| g.state == "completed" }.sort_by { |g| g.name.downcase }
    @archived_goals = all_goals.select { |g| g.state == "archived" }
    # Completed goals join the chip-filterable grid below the active ones so
    # the `completed` chip can isolate them. Archived stays in the separate
    # collapsed-by-default section below.
    @grid_goals = @active_goals + @completed_goals

    @linkable_account_count = Current.family.accounts.where(accountable_type: "Depository").visible.count
    @kpi = kpi_payload(@active_goals)
    @any_pending_pledge = @active_goals.any? { |g| g.open_pledges.any? }
    @show_search = @grid_goals.size > 6
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("goals.index.title"), nil ]
    ]
  end

  def show
    @open_pledges = @goal.open_pledges.reverse_chronological.to_a
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
                             .includes(:open_pledges, linked_accounts: :account_providers)
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
      desired_ids = accounts.map(&:id).to_set
      current_ids = goal.goal_accounts.pluck(:account_id).to_set

      (current_ids - desired_ids).each do |id|
        goal.goal_accounts.where(account_id: id).destroy_all
      end
      additions = accounts.reject { |a| current_ids.include?(a.id) }
      additions.each { |a| goal.goal_accounts.build(account: a) }
      # Save through the goal so currency / depository / family
      # validations fire. `create!` on goal_accounts directly bypasses them
      # and let cross-currency / non-depository attachments through.
      goal.save!
    end

    def kpi_payload(active_goals)
      family = Current.family
      currency = family.primary_currency_code
      today = Date.current

      velocity_30d = family.savings_inflow_velocity(range: (today - 30)..today)
      velocity_prior_30d = family.savings_inflow_velocity(range: (today - 60)..(today - 31))
      delta_amount = velocity_30d - velocity_prior_30d
      delta_percent = velocity_prior_30d.zero? ? nil : ((delta_amount / velocity_prior_30d.abs) * 100).round(1)

      # Sign decoupling: the headline-amount sign reflects this month's
      # direction ("−$200 last 30d" = net outflow); the delta direction
      # (↑/↓ vs prior 30d) goes on the subline. Conflating them produced the
      # "−$1234" + "↓ 27%" tile where the minus looked like a loss but the
      # $1234 was actually the (positive) amount contributed.
      headline_sign = velocity_30d.negative? ? "−" : ""
      delta_direction = if delta_amount.positive? then :up
      elsif delta_amount.negative? then :down
      else :flat
      end

      needs = active_goals
        .select { |g| g.status == :behind }
        .sum { |g| g.monthly_target_amount.to_d }
      behind = active_goals.count { |g| g.status == :behind }
      on_track = active_goals.count { |g| g.status == :on_track }
      reached = active_goals.count { |g| g.status == :reached }
      no_date = active_goals.count { |g| g.status == :no_target_date }
      paused = active_goals.count(&:paused?)

      # Denominator of the "Goals on track" tile. Goals that hit their
      # target are no longer being tracked toward pace, so they don't
      # belong in the fraction; paused goals stop the pace clock on
      # purpose, so they don't either. When this hits zero the tile
      # swaps to a celebration / empty state in the view.
      tracked_total = active_goals.count do |g|
        !g.paused? && g.status != :reached
      end

      {
        currency: currency,
        velocity_30d_money: Money.new(velocity_30d.abs, currency),
        velocity_prior_30d_money: Money.new(velocity_prior_30d.abs, currency),
        velocity_30d_sign: headline_sign,
        velocity_delta_percent: delta_percent,
        velocity_direction: delta_direction,
        needs_this_month_money: Money.new(needs, currency),
        on_track_count: on_track,
        reached_count: reached,
        behind_count: behind,
        no_date_count: no_date,
        paused_count: paused,
        tracked_total: tracked_total,
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
