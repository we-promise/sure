class Assistant::Function::UpdateGoal < Assistant::Function
  STATES = %w[active paused completed archived].freeze

  class << self
    def name = "update_goal"

    def description
      "Updates a family goal, its linked accounts, or its lifecycle state. Use get_goals and get_accounts first."
    end
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
        linked_account_ids: { type: "array", items: { type: "string" }, description: "Full list of fundable account ids" },
        state: { type: "string", enum: STATES, description: "Goal lifecycle state" }
      }
    )
  end

  def call(params = {})
    goal = valid_uuid?(params["id"]) ? family.goals.find_by(id: params["id"]) : nil
    return error("not_found", "Goal not found.") unless goal

    changed = params.keys & %w[name target_amount target_date notes linked_account_ids state]
    return error("no_changes", "Provide at least one field to update.") if changed.empty?

    Goal.transaction do
      attrs = {}
      attrs[:name] = params["name"].to_s.strip if params.key?("name")
      attrs[:target_amount] = BigDecimal(params["target_amount"].to_s) if params.key?("target_amount")
      attrs[:target_date] = parse_date(params["target_date"]) if params.key?("target_date")
      attrs[:notes] = params["notes"] if params.key?("notes")
      goal.update!(attrs) if attrs.any?

      sync_linked_accounts!(goal, params["linked_account_ids"]) if params.key?("linked_account_ids")
      transition_to!(goal, params["state"]) if params.key?("state") && params["state"] != goal.state
    end

    goal.reload
    {
      success: true,
      goal: {
        id: goal.id, name: goal.name, target_amount: goal.target_amount,
        currency: goal.currency, target_date: goal.target_date&.iso8601,
        notes: goal.notes, state: goal.state,
        linked_account_ids: goal.linked_account_ids
      },
      message: "Goal '#{goal.name}' updated."
    }
  rescue Date::Error, ArgumentError => e
    error("invalid_parameters", e.message)
  rescue AASM::InvalidTransition => e
    error("invalid_state_transition", e.message)
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def parse_date(value)
      value.nil? || value == "" ? nil : Date.iso8601(value.to_s)
    end

    def sync_linked_accounts!(goal, raw_ids)
      ids = Array(raw_ids).map(&:to_s).reject(&:blank?).uniq
      raise ActiveRecord::RecordInvalid.new(goal.tap { |g| g.errors.add(:base, "must have at least one linked account") }) if ids.empty?

      accounts = user.accessible_accounts.where(accountable_type: Goal::FUNDABLE_ACCOUNT_TYPES).visible.where(id: ids).to_a
      if accounts.size != ids.size
        raise ActiveRecord::RecordInvalid.new(goal.tap { |g| g.errors.add(:base, "one or more linked accounts are unavailable") })
      end

      currencies = accounts.map(&:currency).uniq
      if currencies.size != 1 || currencies.first != goal.currency
        raise ActiveRecord::RecordInvalid.new(goal.tap { |g| g.errors.add(:base, "linked accounts must use #{goal.currency}") })
      end

      current_ids = goal.goal_accounts.pluck(:account_id)
      removable_ids = user.accessible_accounts.where(id: current_ids).pluck(:id)
      goal.goal_accounts.where(account_id: removable_ids - ids).destroy_all
      existing_ids = goal.goal_accounts.pluck(:account_id)
      accounts.reject { |account| existing_ids.include?(account.id) }.each { |account| goal.goal_accounts.build(account: account) }
      goal.save!
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

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
