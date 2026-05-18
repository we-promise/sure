class Assistant::Function::CreateGoal < Assistant::Function
  class << self
    def name
      "create_goal"
    end

    def description
      <<~INSTRUCTIONS
        Creates a goal for the user's family.

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
          description: "Names of the user's Depository accounts to link. Must contain at least one. Use names exactly as they appear in the available accounts list. The goal's balance is the balance of these accounts."
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

    available = family.accounts.where(accountable_type: "Depository").visible.where(name: linked_account_names)
    missing = linked_account_names - available.pluck(:name).uniq
    if missing.any?
      return error(
        "unknown_accounts",
        "Some account names didn't match the user's Depository accounts.",
        unknown_names: missing,
        available_accounts: depository_account_payload
      )
    end

    # Multiple accounts can share a name. Block silent over-linking by
    # surfacing the ambiguity so the assistant re-asks with disambiguated
    # input rather than attaching every same-named account to the goal.
    grouped = available.group_by(&:name)
    ambiguous_names = grouped.select { |_, accts| accts.size > 1 }.keys
    if ambiguous_names.any?
      return error(
        "ambiguous_accounts",
        "Multiple accounts share a name. Ask the user which one to use.",
        ambiguous_names: ambiguous_names,
        available_accounts: depository_account_payload
      )
    end

    matched = linked_account_names.map { |name| grouped[name].first }

    currencies = matched.map(&:currency).uniq
    if currencies.size > 1
      return error(
        "currency_mismatch",
        "All linked accounts must share the same currency. Found: #{currencies.join(', ')}."
      )
    end

    goal = nil
    Goal.transaction do
      goal = family.goals.new(
        name: name,
        target_amount: target_amount,
        target_date: target_date,
        currency: currencies.first,
        notes: notes.presence,
        color: Goal::COLORS.sample
      )
      matched.each { |a| goal.goal_accounts.build(account: a) }
      goal.save!
    end

    {
      success: true,
      goal_id: goal.id,
      name: goal.name,
      target_amount_formatted: goal.target_amount_money.format,
      currency: goal.currency,
      target_date: goal.target_date&.iso8601,
      url: absolute_url_for(goal),
      linked_account_names: matched.map(&:name),
      message: "Created goal '#{goal.name}' (target #{goal.target_amount_money.format}). View it at #{absolute_url_for(goal)}."
    }
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end

  private
    # Build an absolute URL for the new goal so chat clients (which render
    # outside the request that produced the goal) can link directly. Falls
    # back to the relative path when no host is configured (e.g. self-hosted
    # in a job without ENV).
    def absolute_url_for(goal)
      host_opts = Rails.application.config.action_mailer.default_url_options || {}
      if host_opts[:host].present?
        Rails.application.routes.url_helpers.goal_url(goal, host_opts)
      else
        Rails.application.routes.url_helpers.goal_path(goal)
      end
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
