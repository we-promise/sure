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

    all_goals = Current.family.goals.with_current_balance.alphabetically.includes(:goal_contributions, :linked_accounts).to_a
    @active_goals = all_goals.reject { |g| %w[completed archived].include?(g.state) }
                             .sort_by { |g| [ g.paused? ? 3 : ACTIVE_STATUS_RANK.fetch(g.status, 4), g.name.downcase ] }
    @completed_goals = all_goals.select { |g| g.state == "completed" }
    @archived_goals = all_goals.select { |g| g.state == "archived" }

    @linkable_account_count = Current.family.accounts.where(accountable_type: "Depository").visible.count
    @kpi = kpi_payload(@active_goals)
    @show_search = @active_goals.size > 6
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("goals.index.title"), nil ]
    ]
  end

  def show
    @contributions = @goal.goal_contributions
                                  .sort_by { |c| [ c.contributed_at, c.created_at ] }
                                  .reverse
    @funding_breakdown = funding_breakdown_for(@goal)
    @stats = stats_for(@goal)
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
      create_initial_contribution_if_provided!(@goal, accounts)
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
                             .with_current_balance
                             .includes(goal_contributions: :account, linked_accounts: [])
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

    def create_initial_contribution_if_provided!(goal, accounts)
      amount = params.dig(:goal, :initial_contribution_amount)
      account_id = params.dig(:goal, :initial_contribution_account_id)
      return if amount.blank? || account_id.blank?
      return unless BigDecimal(amount.to_s) > 0

      source = accounts.find { |a| a.id == account_id }
      raise ActiveRecord::RecordInvalid.new(goal) unless source

      goal.goal_contributions.create!(
        account: source,
        amount: amount,
        currency: goal.currency,
        source: "initial",
        contributed_at: Date.current
      )
    end

    def funding_breakdown_for(goal)
      totals = goal.goal_contributions
                   .group_by(&:account_id)
                   .transform_values { |arr| arr.sum(&:amount) }
      goal.linked_accounts.map do |account|
        amount = totals[account.id] || 0
        { account: account, amount: amount, money: Money.new(amount, goal.currency) }
      end
    end

    def kpi_payload(active_goals)
      family = Current.family
      currency = family.primary_currency_code
      today = Date.current

      velocity_30d = family.contribution_velocity(range: (today - 30)..today)
      velocity_prior_30d = family.contribution_velocity(range: (today - 60)..(today - 31))
      delta_amount = velocity_30d - velocity_prior_30d
      delta_percent = velocity_prior_30d.zero? ? nil : ((delta_amount / velocity_prior_30d) * 100).round(1)
      velocity_direction = if delta_amount.positive? then :up
      elsif delta_amount.negative? then :down
      else :flat
      end

      behind = active_goals.select { |g| g.status == :behind }
      on_track = active_goals.select { |g| g.status == :on_track }
      no_date = active_goals.select { |g| g.status == :no_target_date }
      paused = active_goals.select(&:paused?)
      needs = behind.sum { |g| g.monthly_target_amount.to_d }

      {
        currency: currency,
        velocity_30d: velocity_30d,
        velocity_30d_money: Money.new(velocity_30d.abs, currency),
        velocity_prior_30d_money: Money.new(velocity_prior_30d, currency),
        velocity_30d_sign: velocity_direction == :down ? "−" : (velocity_direction == :up ? "+" : ""),
        velocity_delta_amount_money: Money.new(delta_amount.abs, currency),
        velocity_delta_percent: delta_percent,
        velocity_direction: velocity_direction,
        needs_this_month_money: Money.new(needs, currency),
        behind_count: behind.size,
        on_track_count: on_track.size,
        no_date_count: no_date.size,
        paused_count: paused.size,
        active_total: active_goals.size
      }
    end

    def stats_for(goal)
      avg = goal.average_monthly_contribution.to_d
      sub_avg = if goal.monthly_target_amount && goal.monthly_target_amount.to_d > avg
        t("goals.show.stats.needs_per_month", amount: Money.new(goal.monthly_target_amount, goal.currency).format)
      else
        t("goals.show.stats.above_target_pace")
      end
      sub_target = if goal.monthly_target_amount
        t("goals.show.stats.needs_per_month", amount: Money.new(goal.monthly_target_amount, goal.currency).format)
      else
        t("goals.show.stats.no_required_pace")
      end
      summary = projection_summary(goal, avg)

      {
        avg_monthly: avg,
        avg_monthly_sub: sub_avg,
        contributions_count: goal.goal_contributions.size,
        monthly_target_sub: sub_target,
        projection_summary: summary
      }
    end

    def projection_summary(goal, avg_monthly)
      currency = goal.currency
      money = ->(amount) { Money.new(amount, currency).format }

      if goal.completed? || goal.progress_percent >= 100
        t("goals.show.projection.reached")
      elsif goal.target_date.nil?
        t("goals.show.projection.no_target_date")
      elsif goal.monthly_target_amount && avg_monthly < goal.monthly_target_amount
        t("goals.show.projection.behind",
          current: money.call(avg_monthly),
          required: money.call(goal.monthly_target_amount))
      elsif avg_monthly.positive?
        months_to_target = (goal.remaining_amount.to_d / avg_monthly).ceil
        projected_date = Date.current >> months_to_target.to_i
        t("goals.show.projection.on_track",
          date: projected_date.strftime("%b %Y"))
      else
        t("goals.show.projection.no_pace")
      end
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
