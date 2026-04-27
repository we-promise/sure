class SavingsGoalsController < ApplicationController
  before_action :set_savings_goal, only: %i[show edit update destroy pause resume complete archive unarchive]
  before_action :set_backing_accounts, only: %i[new create edit update]
  before_action :set_breadcrumbs


  def index
    state = params[:state].presence_in(%w[all active paused completed archived]) || "all"
    scope = Current.family.savings_goals.alphabetically
    @savings_goals = state == "all" ? scope : scope.where(state: state)
    @state = state
  end

  def show
  end

  def new
    @savings_goal = Current.family.savings_goals.new(state: "active")
  end

  def create
    @savings_goal = Current.family.savings_goals.new(savings_goal_params)
    @savings_goal.account = lookup_account(params.dig(:savings_goal, :account_id))

    begin
      ActiveRecord::Base.transaction do
        @savings_goal.save!
        handle_initial_contribution(@savings_goal)
      end
    rescue ActiveRecord::RecordInvalid
      return render :new, status: :unprocessable_entity
    end

    flash[:notice] = t("savings_goals.create.success")
    respond_to do |format|
      format.html { redirect_to savings_goal_path(@savings_goal) }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, savings_goal_path(@savings_goal)) }
    end
  end

  def edit
  end

  def update
    submitted_account_id = params.dig(:savings_goal, :account_id)
    if submitted_account_id.present?
      candidate = lookup_account(submitted_account_id)
      # Only swap to a non-nil family-scoped account. A foreign account_id
      # returns nil from `lookup_account`; assigning nil would null the
      # `belongs_to :account` association and block unrelated attribute
      # changes (e.g. a name edit) in the same request. Silently ignoring
      # the foreign id keeps the rest of the update flowing through.
      @savings_goal.account = candidate if candidate
    end

    if @savings_goal.update(savings_goal_params)
      flash[:notice] = t("savings_goals.update.success")
      respond_to do |format|
        format.html { redirect_to savings_goal_path(@savings_goal) }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, savings_goal_path(@savings_goal)) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @savings_goal.destroy
    redirect_to savings_goals_path, notice: t("savings_goals.destroy.success")
  end

  def pause
    transition!(:pause!, t("savings_goals.pause.success"))
  end

  def resume
    transition!(:resume!, t("savings_goals.resume.success"))
  end

  def complete
    transition!(:complete!, t("savings_goals.complete.success"))
  end

  def archive
    transition!(:archive!, t("savings_goals.archive.success"))
  end

  def unarchive
    transition!(:unarchive!, t("savings_goals.unarchive.success"))
  end

private
  def set_breadcrumbs
    crumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("savings_goals.index.title"), savings_goals_path ] ]
    if @savings_goal&.persisted?
      crumbs << [ @savings_goal.name, savings_goal_path(@savings_goal) ] if action_name != "show"
      crumbs << [ @savings_goal.name, nil ] if action_name == "show"
      crumbs << [ t("savings_goals.show.actions.edit"), nil ] if action_name == "edit"
    elsif action_name == "new"
      crumbs << [ t("savings_goals.index.new_goal"), nil ]
    else
      crumbs.last[1] = nil
    end
    @breadcrumbs = crumbs
  end

  def set_savings_goal
    @savings_goal = Current.family.savings_goals.find(params[:id])
  end

  def set_backing_accounts
    @backing_accounts = Current.family.accounts
                               .where(classification: "asset",
                                      accountable_type: %w[Depository Investment OtherAsset])
                               .alphabetically
  end

  def savings_goal_params
    # `account_id` is intentionally omitted from the permit list. We
    # assign `@savings_goal.account` manually via `lookup_account`, which
    # scopes the lookup to `Current.family.accounts`. Permitting account_id
    # here would let mass-assignment bypass that check.
    params.require(:savings_goal).permit(
      :name, :target_amount, :target_date, :color, :icon, :notes
    )
  end

  # Scopes the lookup so a foreign account_id never silently associates.
  def lookup_account(account_id)
    return nil if account_id.blank?
    Current.family.accounts.find_by(id: account_id)
  end

  def handle_initial_contribution(goal)
    amount = params.dig(:savings_goal, :initial_contribution).to_d
    return unless amount.positive?
    goal.savings_contributions.create!(
      amount: amount,
      source: "initial",
      contributed_at: Date.current
    )
  end

  def transition!(event, message)
    @savings_goal.public_send(event)
    redirect_to savings_goal_path(@savings_goal), notice: message
  rescue AASM::InvalidTransition => e
    redirect_to savings_goal_path(@savings_goal), alert: e.message
  end
end
