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

    account, account_error = resolve_account(params["account_name"])
    return account_error if account_error

    category, category_error = resolve_category(params["category_name"])
    return category_error if category_error

    series = RecurringTransaction::DeclaredBill.new(
      family: family,
      user: user,
      attrs: {
        name: params["name"],
        amount: params["amount"],
        first_due_on: params["first_due_on"],
        frequency_preset: params["frequency"].presence_in(RecurringTransaction::FrequencyPreset::PRESETS) || "monthly",
        is_income: params["is_income"] == true,
        account_id: account&.id,
        payment_url: params["payment_url"],
        autopay: params["autopay"] == true,
        notes: params["notes"]
      }
    ).build

    if series.errors.none?
      series.category = category if category
      if params["is_income"] != true && params["bill_type"].presence_in(%w[bill subscription installment])
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
    def resolve_account(name)
      return [ nil, nil ] if name.blank?

      account = user.accessible_accounts.find_by(name: name)
      return [ account, nil ] if account

      [ nil, {
        error: "No account named #{name.inspect}",
        hint: "Call get_accounts and retry once with the exact account name."
      } ]
    end

    def resolve_category(name)
      return [ nil, nil ] if name.blank?

      category = family.categories.find_by(name: name)
      return [ category, nil ] if category

      [ nil, {
        error: "No category named #{name.inspect}",
        hint: "Call get_categories and retry once with the exact category name."
      } ]
    end
end
