class Assistant::Function::CreateBill < Assistant::Function
  include Assistant::Function::BillsSupport

  class << self
    def name
      "create_bill"
    end

    def description
      <<~INSTRUCTIONS
        Create a bill, subscription, installment plan or income schedule for the user.

        Rules:
        - amount is always a positive magnitude; set is_income true for income and the
          app derives the sign. Never pass a negative amount.
        - account_name must exactly match a name returned by get_accounts. Omit it to
          create the bill without an account.
        - category_name must exactly match a name returned by get_categories.
        - first_due_on seeds the schedule: its day of month (or weekday for weekly
          cadences) becomes the recurring due day.
        - Transfers between accounts cannot be created here.

        Confirm the details with the user before calling this.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[name amount first_due_on],
      properties: {
        name: { type: "string", description: "What the user calls this bill." },
        amount: { type: "number", minimum: 0.01, description: "Positive magnitude per occurrence." },
        first_due_on: { type: "string", description: "Next due date, YYYY-MM-DD." },
        frequency: {
          type: "string",
          enum: RecurringTransaction::FrequencyPreset::PRESETS,
          description: "Cadence (default monthly)."
        },
        is_income: { type: "boolean", description: "True for a paycheck/income schedule." },
        bill_type: {
          type: "string", enum: %w[bill subscription installment],
          description: "Kind of obligation (ignored for income)."
        },
        account_name: { type: "string", description: "Exact account name from get_accounts." },
        category_name: { type: "string", description: "Exact category name from get_categories." },
        autopay: { type: "boolean" },
        payment_url: { type: "string", description: "Where this bill gets paid." },
        notes: { type: "string" }
      }
    )
  end

  def call(params = {})
    return recurring_disabled_result if recurring_disabled?

    is_income, income_error = resolve_boolean(params, "is_income")
    return income_error if income_error

    autopay, autopay_error = resolve_boolean(params, "autopay")
    return autopay_error if autopay_error

    account, account_error = resolve_account(params["account_name"])
    return account_error if account_error

    category, category_error = resolve_category(params["category_name"])
    return category_error if category_error

    frequency, frequency_error = resolve_frequency(params["frequency"])
    return frequency_error if frequency_error

    series = RecurringTransaction::DeclaredBill.new(
      family: family,
      user: user,
      attrs: {
        name: params["name"],
        amount: params["amount"],
        first_due_on: params["first_due_on"],
        frequency_preset: frequency,
        is_income: is_income,
        account_id: account&.id,
        payment_url: params["payment_url"],
        autopay: autopay,
        notes: params["notes"]
      }
    ).build

    if series.errors.none?
      series.category = category if category
      if !is_income && params["bill_type"].presence_in(%w[bill subscription installment])
        series.bill_type = params["bill_type"]
      end
    end

    unless series.errors.none? && RecurringTransaction::DeclaredBill.save(series)
      return {
        error: series.errors.full_messages.to_sentence,
        hint: "Fix the named fields and retry once."
      }
    end

    {
      created: true,
      bill: serialize_series(series),
      upcoming_due_dates: series.schedule.occurrences_between(Date.current, Date.current + 400).first(3).map(&:iso8601)
    }
  end

  private
    # An unrecognized cadence used to fall back to monthly. The enum word for a
    # once-a-year bill is "annual", so a model offering the equally natural
    # "yearly" turned a $600 premium into a $600 monthly commitment, twelve
    # times the real obligation, with no indication anything had been ignored.
    # A financial write is the wrong place to guess.
    def resolve_frequency(value)
      return [ "monthly", nil ] if value.blank?

      preset = value.to_s.presence_in(RecurringTransaction::FrequencyPreset::PRESETS)
      return [ preset, nil ] if preset

      [ nil, {
        error: "#{value} is not a frequency this app recognizes",
        hint: "Use one of: #{RecurringTransaction::FrequencyPreset::PRESETS.join(', ')}. " \
              "Omit it entirely for monthly."
      } ]
    end

    # Writable, not merely visible: attaching a bill to an account changes
    # what that account's owners see, so a read-only share is not a
    # destination. Namesakes are refused rather than picked between: a
    # financial write is the wrong place to guess.
    def resolve_account(name)
      return [ nil, nil ] if name.blank?

      matches = Account.writable_by(user).where(name: name).limit(2).to_a
      return [ matches.first, nil ] if matches.size == 1

      if matches.empty?
        [ nil, {
          error: "No account named #{name.inspect} that you can add bills to",
          hint: "Call get_accounts and retry once with the exact name of a writable account."
        } ]
      else
        [ nil, {
          error: "More than one account is named #{name.inspect}",
          hint: "Ask the user which one they mean; this tool cannot pick between namesakes."
        } ]
      end
    end

    # Category namesakes cannot exist: names are unique per family
    # (index_categories_on_family_id_and_name), so find_by is unambiguous.
    def resolve_category(name)
      return [ nil, nil ] if name.blank?

      category = family.categories.find_by(name: name)
      return [ category, nil ] if category

      [ nil, {
        error: "No category named #{name.inspect}",
        hint: "Call get_categories and retry once with the exact category name."
      } ]
    end

    # The tool caller does not enforce params_schema, so a string "true" from
    # a loose MCP client would otherwise compare unequal to true and silently
    # flip a paycheck into a bill. An explicit allowlist, not
    # ActiveModel::Type::Boolean, because that cast reads every unrecognized
    # string as true, and a financial write is the wrong place to guess.
    TRUTHY_INPUTS = [ true, "true", "t", "1", 1 ].freeze
    FALSY_INPUTS = [ false, "false", "f", "0", 0 ].freeze

    def resolve_boolean(params, key)
      value = params[key]
      return [ false, nil ] if value.nil?

      normalized = value.is_a?(String) ? value.strip.downcase : value
      return [ true, nil ] if TRUTHY_INPUTS.include?(normalized)
      return [ false, nil ] if FALSY_INPUTS.include?(normalized)

      [ nil, {
        error: "#{key} must be true or false",
        hint: "Pass a JSON boolean, not #{value.inspect}."
      } ]
    end
end
