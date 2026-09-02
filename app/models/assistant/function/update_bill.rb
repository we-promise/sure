class Assistant::Function::UpdateBill < Assistant::Function
  include Assistant::Function::BillsSupport

  # UI-parity only: exactly the fields the edit dialog exposes. No income or
  # transfer flips (they change sign and shape semantics), no end-condition
  # juggling, no currency.
  EDITABLE_BILL_TYPES = %w[bill subscription installment].freeze

  class << self
    def name
      "update_bill"
    end

    def description
      <<~INSTRUCTIONS
        Update one bill's configuration. Only pass the fields being changed.

        Rules:
        - amount is a positive magnitude; the bill keeps its own direction. An amount
          change applies from today forward -- occurrences already due keep the old
          figure, so a rent raise never restates last month's unpaid rent.
        - account_name / category_name must exactly match names from get_accounts /
          get_categories. Pass category_name "Uncategorized" to clear the category.
        - Changing the schedule (frequency / due day) pins it: automatic detection
          will respect it as the user's intent from then on.
        - status "paused" sets the bill aside (no new occurrences); "active" resumes it.
        - bill_type can move between bill, subscription and installment only.

        Confirm the change with the user before calling this.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[bill_id],
      properties: {
        bill_id: { type: "string", description: "The bill's id, exactly as returned by get_bills." },
        name: { type: "string" },
        amount: { type: "number", minimum: 0.01, description: "New positive magnitude; applies forward only." },
        account_name: { type: "string", description: "Exact account name from get_accounts." },
        category_name: { type: "string", description: "Exact category name, or \"Uncategorized\" to clear." },
        bill_type: { type: "string", enum: EDITABLE_BILL_TYPES },
        status: { type: "string", enum: %w[active paused] },
        frequency: {
          type: "string",
          enum: RecurringTransaction::FrequencyPreset::PRESETS,
          description: "New cadence. Combine with due_day_of_month / weekday / month_of_year as the cadence needs."
        },
        due_day_of_month: { type: "integer", minimum: 1, maximum: 31 },
        weekday: { type: "integer", minimum: 0, maximum: 6, description: "0 = Sunday." },
        month_of_year: { type: "integer", minimum: 1, maximum: 12 },
        autopay: { type: "boolean" },
        payment_url: { type: "string" },
        notes: { type: "string" },
        renews_on: { type: "string", description: "YYYY-MM-DD" },
        trial_ends_on: { type: "string", description: "YYYY-MM-DD" }
      }
    )
  end

  def call(params = {})
    return recurring_disabled_result if recurring_disabled?

    series, error = find_writable_series(params["bill_id"])
    return error if error

    changed = []

    # Each step returns an error hash or nil; the first error aborts the call
    # before anything is saved.
    %i[apply_simple_fields apply_bill_type apply_amount apply_account
       apply_category apply_status apply_schedule].each do |step|
      if (error = send(step, series, params, changed))
        return error
      end
    end

    if changed.empty?
      return { error: "No recognized fields to change", hint: "Pass at least one editable field." }
    end

    unless series.save
      return { error: series.errors.full_messages.to_sentence, hint: "Fix the named fields and retry once." }
    end

    { updated: true, changed_fields: changed, bill: serialize_series(series.reload) }
  end

  private
    def apply_simple_fields(series, params, changed)
      { "name" => :name, "autopay" => :autopay, "payment_url" => :payment_url,
        "notes" => :notes, "renews_on" => :renews_on, "trial_ends_on" => :trial_ends_on }.each do |key, attribute|
        next unless params.key?(key)

        value = params[key]

        # AR silently casts an unparseable date string to nil, which would
        # read back as "cleared" instead of "rejected". A blank still clears.
        if %w[renews_on trial_ends_on].include?(key) && value.present?
          begin
            value = Date.parse(value.to_s)
          rescue Date::Error
            return { error: "#{key} is not a valid date", hint: "Use YYYY-MM-DD." }
          end
        end

        series.public_send("#{attribute}=", value)
        changed << key
      end
      nil
    end

    def apply_bill_type(series, params, changed)
      return nil unless params.key?("bill_type")

      unless EDITABLE_BILL_TYPES.include?(series.bill_type)
        return {
          error: "#{series.display_name} is #{series.bill_type} and cannot change kind here",
          hint: "Only bill, subscription and installment kinds are editable."
        }
      end

      unless params["bill_type"].presence_in(EDITABLE_BILL_TYPES)
        return {
          error: "#{params["bill_type"].inspect} is not a kind this tool can set",
          hint: "Use one of: #{EDITABLE_BILL_TYPES.join(', ')}."
        }
      end

      series.bill_type = params["bill_type"]
      changed << "bill_type"
      nil
    end

    # Magnitude in, sign preserved: income is stored negative, so a raw
    # assignment would flip a paycheck into a bill. Forward-only pinning of
    # already-due occurrences is the model's own callback.
    def apply_amount(series, params, changed)
      return nil unless params.key?("amount")

      # BigDecimal parses "Infinity" and "NaN" as non-finite numbers; the tool
      # caller does not enforce params_schema, so both are rejected here the
      # same as unparseable input.
      magnitude = begin
        BigDecimal(params["amount"].to_s).abs
      rescue ArgumentError
        nil
      end
      if magnitude.nil? || !magnitude.finite?
        return { error: "amount is not a number", hint: "Pass a positive numeric magnitude." }
      end
      if magnitude.zero?
        return { error: "amount must be greater than zero", hint: "Pass a positive magnitude." }
      end

      series.amount = series.typed_income? ? -magnitude : magnitude
      changed << "amount"
      nil
    end

    # Writable, not merely visible: attaching a series to an account changes
    # what that account's owners see, so a read-only share is not a
    # destination (same contract as the edit dialog's account resolution).
    def apply_account(series, params, changed)
      return nil unless params.key?("account_name")

      matches = Account.writable_by(user).where(name: params["account_name"]).limit(2).to_a
      if matches.empty?
        return {
          error: "No account named #{params["account_name"].inspect} that you can add bills to",
          hint: "Call get_accounts and retry once with the exact name of a writable account."
        }
      end
      if matches.size > 1
        return {
          error: "More than one account is named #{params["account_name"].inspect}",
          hint: "Ask the user which one they mean; this tool cannot pick between namesakes."
        }
      end

      series.account = matches.first
      changed << "account"
      nil
    end

    def apply_category(series, params, changed)
      return nil unless params.key?("category_name")

      name = params["category_name"]
      if name == "Uncategorized"
        series.category_id = nil
        changed << "category"
        return nil
      end

      # Category namesakes cannot exist: names are unique per family
      # (index_categories_on_family_id_and_name), so find_by is unambiguous.
      category = family.categories.find_by(name: name)
      if category.nil?
        return {
          error: "No category named #{name.inspect}",
          hint: "Call get_categories and retry once with the exact category name."
        }
      end

      series.category = category
      changed << "category"
      nil
    end

    # The stored value the UI's own Pause writes is "inactive"; "paused" is
    # the user-facing word for that state.
    def apply_status(series, params, changed)
      return nil unless params.key?("status")

      case params["status"]
      when "active" then series.status = "active"
      when "paused" then series.status = "inactive"
      else
        return {
          error: "#{params["status"].inspect} is not a status this tool can set",
          hint: "Use active or paused."
        }
      end
      changed << "status"
      nil
    end

    # An AI-applied cadence is user intent by proxy: pin it so detection
    # cannot quietly move it back, exactly as the edit dialog does.
    def apply_schedule(series, params, changed)
      companions = %w[due_day_of_month weekday month_of_year].select { |key| params.key?(key) }

      unless params.key?("frequency")
        # Day details without a cadence would be silently dropped; a financial
        # write is the wrong place to guess which cadence they belong to.
        if companions.any?
          return {
            error: "#{companions.to_sentence} need frequency alongside them",
            hint: "Pass frequency too (get_bill_details shows the current one)."
          }
        end
        return nil
      end

      # Same contract as create_bill: an unrecognized cadence is rejected, not
      # guessed around, and the other edits in this call are not saved with it.
      unless params["frequency"].to_s.presence_in(RecurringTransaction::FrequencyPreset::PRESETS)
        return {
          error: "#{params["frequency"]} is not a frequency this app recognizes",
          hint: "Use one of: #{RecurringTransaction::FrequencyPreset::PRESETS.join(', ')}."
        }
      end

      applied = RecurringTransaction::FrequencyPreset.apply(
        series,
        preset: params["frequency"],
        day_of_month: params["due_day_of_month"],
        weekday: params["weekday"],
        month_of_year: params["month_of_year"]
      )

      if applied
        series.pin_schedule
        changed << "schedule"
      end
      nil
    end
end
