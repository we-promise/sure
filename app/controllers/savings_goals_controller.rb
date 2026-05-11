class SavingsGoalsController < ApplicationController
  before_action :set_savings_goal, only: %i[show edit update destroy pause resume complete archive unarchive]

  STATE_FILTERS = %w[all active paused completed archived].freeze
  ACTIVE_STATUS_RANK = { behind: 0, on_track: 1, no_target_date: 2 }.freeze

  def index
    @counts = STATE_FILTERS.each_with_object({}) do |state, h|
      h[state] = state == "all" ? Current.family.savings_goals.count : Current.family.savings_goals.where(state: state).count
    end

    all_goals = Current.family.savings_goals.with_current_balance.alphabetically.includes(:savings_contributions, :linked_accounts).to_a
    @active_goals = all_goals.reject { |g| %w[completed archived].include?(g.state) }
                             .sort_by { |g| [ g.paused? ? 3 : ACTIVE_STATUS_RANK.fetch(g.status, 4), g.name.downcase ] }
    @completed_goals = all_goals.select { |g| g.state == "completed" }
    @archived_goals = all_goals.select { |g| g.state == "archived" }

    @linkable_account_count = Current.family.accounts.where(accountable_type: "Depository").visible.count
    @kpi = kpi_payload(@active_goals)
    @show_search = @active_goals.size > 6
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("savings_goals.index.title"), nil ]
    ]
  end

  def show
    @contributions = @savings_goal.savings_contributions
                                  .sort_by { |c| [ c.contributed_at, c.created_at ] }
                                  .reverse
    @funding_breakdown = funding_breakdown_for(@savings_goal)
    @stats = stats_for(@savings_goal)
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("savings_goals.index.title"), savings_goals_path ],
      [ @savings_goal.name, nil ]
    ]
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
      @savings_goal = Current.family.savings_goals
                             .with_current_balance
                             .includes(savings_contributions: :account, linked_accounts: [])
                             .find(params[:id])
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
        t("savings_goals.show.stats.needs_per_month", amount: Money.new(goal.monthly_target_amount, goal.currency).format)
      else
        t("savings_goals.show.stats.above_target_pace")
      end
      sub_target = if goal.monthly_target_amount
        t("savings_goals.show.stats.needs_per_month", amount: Money.new(goal.monthly_target_amount, goal.currency).format)
      else
        t("savings_goals.show.stats.no_required_pace")
      end
      summary = projection_summary(goal, avg)

      {
        avg_monthly: avg,
        avg_monthly_sub: sub_avg,
        contributions_count: goal.savings_contributions.size,
        monthly_target_sub: sub_target,
        projection_summary: summary
      }
    end

    def projection_summary(goal, avg_monthly)
      currency = goal.currency
      money = ->(amount) { Money.new(amount, currency).format }

      if goal.completed? || goal.progress_percent >= 100
        t("savings_goals.show.projection.reached")
      elsif goal.target_date.nil?
        t("savings_goals.show.projection.no_target_date")
      elsif goal.monthly_target_amount && avg_monthly < goal.monthly_target_amount
        t("savings_goals.show.projection.behind",
          current: money.call(avg_monthly),
          required: money.call(goal.monthly_target_amount))
      elsif avg_monthly.positive?
        months_to_target = (goal.remaining_amount.to_d / avg_monthly).ceil
        projected_date = Date.current >> months_to_target.to_i
        t("savings_goals.show.projection.on_track",
          date: projected_date.strftime("%b %Y"))
      else
        t("savings_goals.show.projection.no_pace")
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
