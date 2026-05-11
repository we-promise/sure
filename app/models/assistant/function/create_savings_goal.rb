class Assistant::Function::CreateSavingsGoal < Assistant::Function
  class << self
    def name
      "create_savings_goal"
    end

    def description
      <<~INSTRUCTIONS
        Creates a savings goal for the user's family.

        Use when the user describes a target they want to save toward — e.g.
        "vacation in 4 months for $5000", "downpayment for a car next year",
        "build an emergency fund of $10k".

        Before calling, confirm the key details by paraphrasing back to the
        user: the name, target amount, target date (if mentioned), and which
        of their accounts will fund it. Only call once they've confirmed.

        Constraints:
        - The goal must link to at least one of the user's Depository
          accounts (checking, savings, HSA, CD, money-market).
        - All linked accounts must share the same currency.
        - Use account names exactly as listed in the user's Depository
          accounts.

        On success returns the new goal's URL so you can point the user to
        it. On a soft failure (e.g. account name doesn't match), the
        response includes the available account list so you can re-ask.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[name target_amount linked_account_names],
      properties: {
        name: {
          type: "string",
          description: "Short goal name, e.g. 'Vacation in Italy'."
        },
        target_amount: {
          type: "number",
          description: "Total amount to save, in the linked accounts' currency."
        },
        target_date: {
          type: "string",
          description: "Optional ISO 8601 date (YYYY-MM-DD) for when the user wants to reach the target."
        },
        linked_account_names: {
          type: "array",
          items: { type: "string" },
          description: "Names of the user's Depository accounts to link. Must contain at least one. Use names exactly as they appear in the available accounts list."
        },
        initial_contribution: {
          type: "object",
          description: "Optional starting contribution at creation time.",
          properties: {
            amount: { type: "number" },
            source_account_name: { type: "string", description: "Must be one of the linked_account_names." }
          }
        },
        notes: {
          type: "string",
          description: "Optional freeform notes."
        }
      }
    )
  end

  def call(params = {})
    name = params["name"].to_s.strip
    target_amount = parse_decimal(params["target_amount"])
    target_date = parse_date(params["target_date"])
    linked_account_names = Array(params["linked_account_names"]).map { |n| n.to_s.strip }.reject(&:blank?)
    initial = params["initial_contribution"]
    notes = params["notes"].to_s.strip

    return error("name_required", "Please provide a name for the goal.") if name.blank?

    return error("target_amount_invalid", "Target amount must be greater than zero.") unless target_amount && target_amount > 0

    if linked_account_names.empty?
      return error(
        "no_linked_accounts",
        "Please specify at least one Depository account to link to this goal.",
        available_accounts: depository_account_payload
      )
    end

    matched = family.accounts.where(accountable_type: "Depository").visible.where(name: linked_account_names).to_a
    missing = linked_account_names - matched.map(&:name)
    if missing.any?
      return error(
        "unknown_accounts",
        "Some account names didn't match the user's Depository accounts.",
        unknown_names: missing,
        available_accounts: depository_account_payload
      )
    end

    currencies = matched.map(&:currency).uniq
    if currencies.size > 1
      return error(
        "currency_mismatch",
        "All linked accounts must share the same currency. Found: #{currencies.join(', ')}."
      )
    end

    goal = nil
    SavingsGoal.transaction do
      goal = family.savings_goals.new(
        name: name,
        target_amount: target_amount,
        target_date: target_date,
        currency: currencies.first,
        notes: notes.presence,
        color: SavingsGoal::COLORS.sample
      )
      matched.each { |a| goal.savings_goal_accounts.build(account: a) }
      goal.save!

      create_initial_contribution!(goal, matched, initial)
    end

    {
      success: true,
      goal_id: goal.id,
      name: goal.name,
      target_amount_formatted: goal.target_amount_money.format,
      currency: goal.currency,
      target_date: goal.target_date&.iso8601,
      url: Rails.application.routes.url_helpers.savings_goal_path(goal),
      linked_account_names: matched.map(&:name),
      message: "Created savings goal '#{goal.name}' (target #{goal.target_amount_money.format}). View it at #{Rails.application.routes.url_helpers.savings_goal_path(goal)}."
    }
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    def create_initial_contribution!(goal, matched_accounts, initial)
      return unless initial.is_a?(Hash)

      amount = parse_decimal(initial["amount"])
      return unless amount && amount > 0

      source = matched_accounts.find { |a| a.name == initial["source_account_name"].to_s }
      raise ActiveRecord::RecordInvalid.new(goal) unless source

      goal.savings_contributions.create!(
        account: source,
        amount: amount,
        currency: goal.currency,
        source: "initial",
        contributed_at: Date.current
      )
    end

    def parse_decimal(value)
      return nil if value.nil?
      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def parse_date(value)
      return nil if value.blank?
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def depository_account_payload
      family.accounts.where(accountable_type: "Depository").visible.pluck(:name, :currency).map { |n, c| { name: n, currency: c } }
    end

    def error(key, message, extras = {})
      { success: false, error: key, message: message }.merge(extras)
    end
end
