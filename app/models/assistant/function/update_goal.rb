class Assistant::Function::UpdateGoal < Assistant::Function
  STATES = %w[active paused completed archived].freeze

  class << self
    def name = "update_goal"
    def description = "Updates a family goal, its complete funding allocation, or lifecycle state. Use get_goals and get_accounts first."
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: { type: "string", description: "Goal ID from get_goals" },
        name: { type: "string", description: "New goal name" },
        target_amount: { type: "number", exclusiveMinimum: 0, description: "New target amount" },
        target_date: { type: [ "string", "null" ], format: "date", description: "New target date, or null to clear" },
        notes: { type: [ "string", "null" ], description: "New notes, or null to clear" },
        funding_accounts: Assistant::Function::GoalFundingSelection.schema,
        state: { type: "string", enum: STATES, description: "Goal lifecycle state" }
      }
    )
  end

  def call(params = {})
    goal = valid_uuid?(params["id"]) ? family.goals.find_by(id: params["id"]) : nil
    return error("not_found", "Goal not found.") unless goal

    changed = params.keys & %w[name target_amount target_date notes funding_accounts state]
    return error("no_changes", "Provide at least one field to update.") if changed.empty?

    Goal.transaction do
      goal.lock!
      attrs = goal_attributes(params)
      goal.assign_attributes(attrs) if attrs.any?
      replace_funding!(goal, params["funding_accounts"]) if params.key?("funding_accounts")
      goal.save! if goal.changed? || goal.goal_accounts.any?(&:changed?) || goal.goal_accounts.any?(&:marked_for_destruction?)
      transition_to!(goal, params["state"]) if params.key?("state") && params["state"] != goal.state
    end

    goal.reload
    {
      success: true,
      goal: {
        id: goal.id,
        name: goal.name,
        target_amount: goal.target_amount,
        currency: goal.currency,
        target_date: goal.target_date&.iso8601,
        notes: goal.notes,
        state: goal.state,
        funding_accounts: goal.goal_accounts.map { |link| { account_id: link.account_id, allocated_amount: link.allocated_amount } }
      },
      message: "Goal '#{goal.name}' updated."
    }
  rescue Account::MutationAccess::Denied
    error("unknown_accounts", "One or more funding accounts are no longer accessible.")
  rescue Assistant::Function::GoalFundingSelection::Invalid => e
    error(e.key, e.message, e.extras)
  rescue Date::Error, ArgumentError => e
    error("invalid_parameters", e.message)
  rescue AASM::InvalidTransition => e
    error("invalid_state_transition", e.message)
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def goal_attributes(params)
      attrs = {}
      attrs[:name] = params["name"].to_s.strip if params.key?("name")
      attrs[:target_amount] = BigDecimal(params["target_amount"].to_s) if params.key?("target_amount")
      attrs[:target_date] = parse_date(params["target_date"]) if params.key?("target_date")
      attrs[:notes] = params["notes"] if params.key?("notes")
      attrs
    end

    def replace_funding!(goal, raw)
      goal.goal_accounts.includes(:account).load
      current_accounts = goal.goal_accounts.map(&:account)
      current_ids = current_accounts.map(&:id)
      visible_current_ids = Assistant::Function::GoalFundingSelection
        .fundable_accounts_for(user)
        .where(id: current_ids)
        .pluck(:id)
      raise_inaccessible_existing_funding! if (current_ids - visible_current_ids).any?

      selection = Assistant::Function::GoalFundingSelection.new(user:, family:, raw:, goal:).resolve!
      accounts_to_lock = (current_accounts + selection.accounts).uniq(&:id)
      locked = Account::MutationAccess.lock!(accounts: accounts_to_lock, user:, level: Account::MutationAccess::READ)
      fundable_ids = Assistant::Function::GoalFundingSelection
        .fundable_accounts_for(user)
        .where(id: accounts_to_lock.map(&:id))
        .pluck(:id)
      raise_inaccessible_existing_funding! if (current_ids - fundable_ids).any?
      raise Account::MutationAccess::Denied if (selection.accounts.map(&:id) - fundable_ids).any?

      locked_funding_accounts = selection.accounts.map { |account| locked.fetch(account.id.to_s) }
      currencies = locked_funding_accounts.map(&:currency).uniq
      unless currencies == [ goal.currency ]
        raise ActiveRecord::RecordInvalid.new(goal.tap { |record| record.errors.add(:base, "funding accounts must use #{goal.currency}") })
      end

      desired_ids = locked_funding_accounts.map(&:id)
      goal.goal_accounts.each do |link|
        link.mark_for_destruction unless link.account_id.in?(desired_ids)
      end
      links_by_account = goal.goal_accounts.reject(&:marked_for_destruction?).index_by(&:account_id)
      locked_funding_accounts.each do |account|
        link = links_by_account[account.id] || goal.goal_accounts.build(account:)
        link.allocated_amount = selection.allocations.fetch(account.id.to_s)
      end
    end

    def raise_inaccessible_existing_funding!
      raise Assistant::Function::GoalFundingSelection::Invalid.new(
        "inaccessible_existing_funding",
        "This goal contains a funding account that is no longer accessible. Its funding cannot be replaced."
      )
    end

    def parse_date(value)
      value.nil? || value == "" ? nil : Date.iso8601(value.to_s)
    end

    def transition_to!(goal, state)
      raise ArgumentError, "state must be one of: #{STATES.join(", ")}" unless STATES.include?(state)

      event = case state
      when "paused" then :pause
      when "completed" then :complete
      when "archived" then :archive
      when "active"
        { "paused" => :resume, "completed" => :reopen, "archived" => :unarchive }.fetch(goal.state)
      end
      goal.public_send("#{event}!")
    end

    def error(key, message, extras = {})
      { success: false, error: key, message: }.merge(extras)
    end
end
