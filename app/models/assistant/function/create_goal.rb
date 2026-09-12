class Assistant::Function::CreateGoal < Assistant::Function
  class << self
    def name = "create_goal"

    def description
      <<~INSTRUCTIONS
        Creates a goal backed by accessible Depository or Investment accounts.

        Use get_accounts first. Pass one complete funding_accounts list using stable
        account IDs. Each account must explicitly use either whole_account or
        fixed_amount allocation. Accounts already claimed in full require fixed_amount.
      INSTRUCTIONS
    end
  end

  def strict_mode? = false

  def params_schema
    build_schema(
      required: %w[name target_amount funding_accounts],
      properties: {
        name: { type: "string", description: "Short goal name" },
        target_amount: { type: "number", exclusiveMinimum: 0, description: "Total target in the funding accounts' currency" },
        target_date: { type: [ "string", "null" ], format: "date", description: "Optional target date in YYYY-MM-DD format" },
        funding_accounts: Assistant::Function::GoalFundingSelection.schema,
        notes: { type: [ "string", "null" ], description: "Optional notes" }
      }
    )
  end

  def call(params = {})
    name = params["name"].to_s.strip
    return error("name_required", "Please provide a name for the goal.") if name.blank?

    target_amount = parse_decimal(params["target_amount"])
    return error("target_amount_invalid", "Target amount must be finite and greater than zero.") unless target_amount&.finite? && target_amount.positive?

    selection = funding_selection(params["funding_accounts"]).resolve!
    target_date = parse_date(params["target_date"])

    goal = Goal.transaction do
      locked = Account::MutationAccess.lock!(accounts: selection.accounts, user:, level: Account::MutationAccess::READ)
      locked_funding_accounts = selection.accounts.map { |account| locked.fetch(account.id.to_s) }
      fundable_ids = Assistant::Function::GoalFundingSelection
        .fundable_accounts_for(user)
        .where(id: locked_funding_accounts.map(&:id))
        .pluck(:id)
      raise Account::MutationAccess::Denied unless fundable_ids.size == locked_funding_accounts.size

      currencies = locked_funding_accounts.map(&:currency).uniq
      unless currencies.one?
        raise Assistant::Function::GoalFundingSelection::Invalid.new(
          "currency_mismatch",
          "All funding accounts must share one currency. Found: #{currencies.join(', ')}."
        )
      end
      created = family.goals.new(
        name:,
        target_amount:,
        target_date:,
        currency: currencies.first,
        notes: params["notes"].presence,
        color: Goal::COLORS.sample
      )
      locked_funding_accounts.each do |account|
        created.goal_accounts.build(account:, allocated_amount: selection.allocations.fetch(account.id.to_s))
      end
      created.save!
      created
    end

    {
      success: true,
      goal_id: goal.id,
      name: goal.name,
      target_amount_formatted: goal.target_amount_money.format,
      currency: goal.currency,
      target_date: goal.target_date&.iso8601,
      url: absolute_url_for(goal),
      funding_accounts: goal.goal_accounts.map { |link| { account_id: link.account_id, allocated_amount: link.allocated_amount } },
      message: "Created goal '#{goal.name}' (target #{goal.target_amount_money.format}). View it at #{absolute_url_for(goal)}."
    }
  rescue Account::MutationAccess::Denied
    error("unknown_accounts", "One or more funding accounts are no longer accessible.")
  rescue Assistant::Function::GoalFundingSelection::Invalid => e
    error(e.key, e.message, e.extras)
  rescue Date::Error
    error("invalid_date", "target_date must use YYYY-MM-DD format.")
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def funding_selection(raw)
      Assistant::Function::GoalFundingSelection.new(user:, family:, raw:)
    end

    def absolute_url_for(goal)
      host_opts = Rails.application.config.action_mailer.default_url_options || {}
      if host_opts[:host].present?
        Rails.application.routes.url_helpers.goal_url(goal, host_opts)
      else
        Rails.application.routes.url_helpers.goal_path(goal)
      end
    end

    def parse_decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def parse_date(value)
      value.blank? ? nil : Date.iso8601(value.to_s)
    end

    def error(key, message, extras = {})
      { success: false, error: key, message: }.merge(extras)
    end
end
