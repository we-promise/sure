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
          cadences) becomes the recurring due day. frequency "once" is a single
          occurrence on first_due_on and does not repeat. anchor_date is the same
          date under the name update_bill uses; pass either one (both must agree).
        - frequency "custom" repeats every interval_count interval_units counted
          from first_due_on: every 3 weeks from 2026-11-24 falls due 2026-11-24,
          2026-12-15, 2027-01-05. interval_count and interval_unit are required with
          custom and refused with any other frequency. Bills repeat by week, month or
          year, so interval_unit "day" works in whole weeks only. A custom cadence
          that matches a named one reads back as it (every 2 weeks is biweekly).
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
      required: %w[name amount],
      properties: {
        name: { type: "string", description: "What the user calls this bill." },
        amount: { type: "number", minimum: 0.01, description: "Positive magnitude per occurrence." },
        first_due_on: { type: "string", description: "Next due date, YYYY-MM-DD. Required unless anchor_date is given." },
        anchor_date: { type: "string", description: "Same as first_due_on, YYYY-MM-DD: the first due date the schedule counts from." },
        frequency: {
          type: "string",
          enum: FREQUENCIES,
          description: "Cadence (default monthly). custom needs interval_count and interval_unit."
        },
        interval_count: { type: "integer", minimum: 1, description: INTERVAL_COUNT_DESCRIPTION },
        interval_unit: { type: "string", enum: CUSTOM_INTERVAL_UNITS, description: INTERVAL_UNIT_DESCRIPTION },
        is_income: { type: "boolean", description: "True for a paycheck/income schedule." },
        bill_type: {
          type: "string", enum: %w[bill subscription installment],
          description: "Kind of obligation (ignored for income)."
        },
        account_name: { type: "string", description: "Exact account name from get_accounts." },
        category_name: { type: "string", description: "Exact category name from get_categories." },
        autopay: { type: "boolean" },
        payment_url: { type: "string", description: "Where this bill gets paid." },
        notes: { type: "string" },
        bank_reference: { type: "string", description: BANK_REFERENCE_DESCRIPTION },
        reference_only: { type: "boolean", description: REFERENCE_ONLY_DESCRIPTION }
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

    interval, interval_error = resolve_custom_interval(params, frequency)
    return interval_error if interval_error

    first_due_on, due_error = resolve_first_due_on(params)
    return due_error if due_error

    series = RecurringTransaction::DeclaredBill.new(
      family: family,
      user: user,
      attrs: {
        name: params["name"],
        amount: params["amount"],
        first_due_on: first_due_on,
        frequency_preset: interval ? RecurringTransaction::FrequencyPreset::INTERVAL : frequency,
        frequency_interval: interval&.first,
        frequency_interval_unit: interval&.last,
        is_income: is_income,
        account_id: account&.id,
        payment_url: params["payment_url"],
        autopay: autopay,
        notes: params["notes"],
        bank_reference: params["bank_reference"],
        reference_only: params["reference_only"]
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

    # From the first due date when it is still ahead: the schedule's grid runs
    # backward too, and dates before it were never this bill's obligations.
    from = [ Date.current, series.anchor_date ].compact.max

    {
      created: true,
      bill: serialize_series(series),
      upcoming_due_dates: series.schedule.occurrences_between(from, from + 400).first(3).map(&:iso8601)
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

      frequency = value.to_s.presence_in(FREQUENCIES)
      return [ frequency, nil ] if frequency

      [ nil, {
        error: "#{value} is not a frequency this app recognizes",
        hint: "Use one of: #{FREQUENCIES.join(', ')}. Omit it entirely for monthly."
      } ]
    end

    # anchor_date is first_due_on under the name update_bill gives the date a
    # schedule counts from, so either names it. Two different dates are two
    # answers to one question, and are refused rather than picked between.
    def resolve_first_due_on(params)
      first_due_on = params["first_due_on"].presence
      return [ first_due_on, nil ] if params["anchor_date"].blank?

      anchor = strict_date(params["anchor_date"])
      return [ nil, { error: "anchor_date is not a valid date", hint: "Use YYYY-MM-DD." } ] if anchor.nil?

      if first_due_on && lenient_date(first_due_on) != anchor
        return [ nil, {
          error: "first_due_on and anchor_date name different dates",
          hint: "They are the same date here; pass just one of them."
        } ]
      end

      [ anchor, nil ]
    end

    def lenient_date(value)
      Date.parse(value.to_s)
    rescue Date::Error
      nil
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
end
