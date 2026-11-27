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
        - frequency "custom" repeats every interval_count interval_units. Both are
          required with custom and refused with any other frequency. Bills repeat by
          week, month or year, so interval_unit "day" works in whole weeks only.
        - anchor_date (YYYY-MM-DD) is the bill's next due date and, from then on, the
          date its cadence counts from. Passed alone it moves the current cadence; with
          frequency the new cadence starts there. due_day_of_month / weekday /
          month_of_year default to the anchor's. Every 3 weeks anchored on 2026-11-24
          falls due 2026-11-24, 2026-12-15, 2027-01-05. Pass anchor_date with a custom
          cadence so it starts where the user expects.
        - Re-anchoring rebuilds only the open, unpaid occurrences due from today on.
          Paid and partially paid occurrences and their payments never change, and
          past ones change only as skip_open_before_anchor below allows.
          anchor_date cannot fall before the last occurrence with a payment, and
          installment plans and semimonthly bills cannot be re-anchored here.
        - Open occurrences already past and due before the new anchor stay owed and are
          listed in occurrences.left_open_before_anchor. skip_open_before_anchor true
          marks the ones without any payment skipped instead (never paid).
        - dry_run true checks the whole change and returns the occurrences it would
          create, remove and skip, without saving anything. Preview schedule changes
          this way and confirm them with the user before calling again without it.
        - Changing the schedule (frequency / due day / anchor_date) pins it: automatic
          detection will respect it as the user's intent from then on.
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
          enum: FREQUENCIES,
          description: "New cadence. once is a single occurrence on the bill's current due date (or on anchor_date). " \
                       "custom needs interval_count and interval_unit. Combine other cadences with " \
                       "due_day_of_month / weekday / month_of_year as needed."
        },
        interval_count: { type: "integer", minimum: 1, description: INTERVAL_COUNT_DESCRIPTION },
        interval_unit: { type: "string", enum: CUSTOM_INTERVAL_UNITS, description: INTERVAL_UNIT_DESCRIPTION },
        anchor_date: {
          type: "string",
          description: "YYYY-MM-DD. The bill's next due date; its cadence counts from this date from now on."
        },
        skip_open_before_anchor: {
          type: "boolean",
          description: "With anchor_date: mark open, payment-free occurrences already due before it skipped. Default false."
        },
        dry_run: {
          type: "boolean",
          description: "Validate and return the occurrences that would be created, removed and skipped, without saving. Default false."
        },
        due_day_of_month: { type: "integer", minimum: 1, maximum: 31 },
        weekday: { type: "integer", minimum: 0, maximum: 6, description: "0 = Sunday." },
        month_of_year: { type: "integer", minimum: 1, maximum: 12 },
        autopay: { type: "boolean" },
        payment_url: { type: "string" },
        notes: { type: "string" },
        bank_reference: { type: "string", description: "#{BANK_REFERENCE_DESCRIPTION} Empty string clears it." },
        reference_only: { type: "boolean", description: REFERENCE_ONLY_DESCRIPTION },
        renews_on: { type: "string", description: "YYYY-MM-DD" },
        trial_ends_on: { type: "string", description: "YYYY-MM-DD" }
      }
    )
  end

  def call(params = {})
    return recurring_disabled_result if recurring_disabled?

    series, error = find_writable_series(params["bill_id"])
    return error if error

    dry_run, error = resolve_boolean(params, "dry_run")
    return error if error

    changed = []
    # Set by apply_schedule when the call re-anchors the series. Reset here
    # because one instance can serve several calls in a chat.
    @anchor = nil
    @skip_open_before_anchor = false

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

    edit = RecurringTransaction::ScheduleEdit.new(series, anchor: @anchor, skip_open_before_anchor: @skip_open_before_anchor)
    unless (report = edit.save(dry_run: dry_run))
      return { error: series.errors.full_messages.to_sentence, hint: "Fix the named fields and retry once." }
    end

    result = if dry_run
      { dry_run: true, changed_fields: changed }
    else
      { updated: true, changed_fields: changed, bill: serialize_series(series.reload) }
    end
    result[:occurrences] = report.to_h if dry_run || changed.include?("schedule")

    if report.left_open_before_anchor.any?
      result[:note] = "The open occurrences in left_open_before_anchor predate the new anchor and are still owed. " \
                      "Ask the user whether they were paid (record_bill_payment) or should be skipped " \
                      "(skip_bill_occurrence, or skip_open_before_anchor with the same anchor_date)."
    end

    result
  end

  private
    def apply_simple_fields(series, params, changed)
      { "name" => :name, "autopay" => :autopay, "payment_url" => :payment_url,
        "notes" => :notes, "bank_reference" => :bank_reference, "reference_only" => :reference_only, "renews_on" => :renews_on, "trial_ends_on" => :trial_ends_on }.each do |key, attribute|
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
      anchoring = params["anchor_date"].present?

      skip_open, error = resolve_boolean(params, "skip_open_before_anchor")
      return error if error

      if skip_open && !anchoring
        return {
          error: "skip_open_before_anchor needs anchor_date",
          hint: "Pass the new anchor_date the skipped occurrences fall before."
        }
      end

      # Day details without a cadence would be silently dropped; a financial
      # write is the wrong place to guess which cadence they belong to.
      if companions.any? && !params.key?("frequency")
        return {
          error: "#{companions.to_sentence} need frequency alongside them",
          hint: "Pass frequency too (get_bill_details shows the current one)."
        }
      end

      # Same contract as create_bill: an unrecognized cadence is rejected, not
      # guessed around, and the other edits in this call are not saved with it.
      if params.key?("frequency") && !params["frequency"].to_s.presence_in(FREQUENCIES)
        return {
          error: "#{params["frequency"]} is not a frequency this app recognizes",
          hint: "Use one of: #{FREQUENCIES.join(', ')}."
        }
      end

      frequency = params["frequency"]
      interval, error = resolve_custom_interval(params, frequency)
      return error if error

      if anchoring
        return reanchor(series, frequency, interval, params, changed, skip_open: skip_open)
      end
      return nil unless params.key?("frequency")

      applied, error = apply_cadence(series, frequency, interval, params)
      return error if error

      if applied
        series.pin_schedule
        changed << "schedule"
      end
      nil
    end

    # The anchor becomes the bill's next due date and the day its cadence
    # counts from. Without a frequency it moves the cadence the bill already
    # has; with one, the new cadence starts there. Either way the day details
    # follow the anchor unless given, so the anchor is a due date by
    # construction, and given ones that disagree with it are refused.
    def reanchor(series, frequency, interval, params, changed, skip_open:)
      anchor = strict_date(params["anchor_date"])
      return { error: "anchor_date is not a valid date", hint: "Use YYYY-MM-DD." } if anchor.nil?

      # A counted plan's payments run from its anchor, so moving it would
      # restart the plan. Read before anything below changes the series:
      # frequency once rewrites the count to one, which would wave the plan
      # through as a one-off and drop its remaining payments.
      if (payments = counted_plan_payments(series))
        return {
          error: "#{series.display_name} is a plan of #{payments} #{'payment'.pluralize(payments)} counted from its first one",
          hint: "Moving its start would restart that count, so installment plans cannot be re-anchored here. " \
                "Tell the user to adjust it on the Bills page."
        }
      end

      if frequency.nil?
        frequency, interval, error = current_cadence(series)
        return error if error
      end

      if frequency == "semimonthly"
        return {
          error: "A twice-monthly bill has no single start date to move",
          hint: "Change its days with frequency semimonthly and due_day_of_month instead, or pick another cadence."
        }
      end

      last_paid = series.last_paid_due_on
      if last_paid && anchor < last_paid
        return {
          error: "anchor_date #{anchor.iso8601} is before #{last_paid.iso8601}, the last occurrence of " \
                 "#{series.display_name} with a payment on it",
          hint: "Paid cycles are history the schedule continues from. Use an anchor_date on or after #{last_paid.iso8601}."
        }
      end

      series.restart_schedule_on(anchor)
      _, error = apply_cadence(series, frequency, interval, params, anchor: anchor)
      return error if error

      unless frequency == RecurringTransaction::FrequencyPreset::ONCE || due_on_schedule?(series, anchor)
        return {
          error: "No occurrence of the resulting schedule falls on anchor_date #{anchor.iso8601}",
          hint: "Leave out due_day_of_month / weekday / month_of_year so they follow anchor_date, and check " \
                "the bill's end date and weekend handling in get_bill_details."
        }
      end

      @anchor = anchor
      @skip_open_before_anchor = skip_open
      series.pin_schedule
      changed << "schedule"
      nil
    end

    # The payment count of a saved installment or counted plan, or nil for
    # any other bill. From the stored row: an earlier step of this call may
    # already have reassigned bill_type. A one-off is a plan of one only in
    # storage, and moves like any date.
    def counted_plan_payments(series)
      return nil unless series.attribute_in_database("end_mode") == "after_count"

      count = series.attribute_in_database("end_after_count").to_i
      installment = series.attribute_in_database("bill_type") == "installment"
      count if installment || count > 1
    end

    # [applied, nil] or [nil, error]. A refused cadence (a paid one-off's
    # date, say) is reported, not saved around: the save would clear the
    # error and drop the change.
    def apply_cadence(series, frequency, interval, params, anchor: nil)
      applied = RecurringTransaction::FrequencyPreset.apply(
        series,
        preset: interval ? RecurringTransaction::FrequencyPreset::INTERVAL : frequency,
        day_of_month: params["due_day_of_month"] || anchor&.day,
        weekday: params["weekday"] || anchor&.wday,
        month_of_year: params["month_of_year"] || anchor&.month,
        interval: interval&.first,
        interval_unit: interval&.last,
        once_on: anchor
      )

      return [ applied, nil ] if series.errors.none?

      [ nil, { error: series.errors.full_messages.to_sentence, hint: "Fix the named fields and retry once." } ]
    end

    # The bill's cadence as this tool's frequency and interval, for an anchor
    # passed alone. A shape the tool cannot express (an nth weekday, or two
    # rules) has nothing it could re-apply from the new date.
    def current_cadence(series)
      detection = RecurringTransaction::FrequencyPreset.detect(series)

      case detection.key
      when RecurringTransaction::FrequencyPreset::INTERVAL
        [ RecurringTransaction::FrequencyPreset::CUSTOM, [ detection.interval, detection.interval_unit ], nil ]
      when RecurringTransaction::FrequencyPreset::CUSTOM
        [ nil, nil, {
          error: "#{series.display_name} has a cadence this tool cannot re-anchor as it is",
          hint: "Pass frequency (with interval_count and interval_unit for custom) alongside anchor_date to replace it."
        } ]
      else
        [ detection.key, nil, nil ]
      end
    end

    # On the raw schedule, before weekend handling moves it: the anchor is the
    # occurrence's identity even when it is paid a day early.
    def due_on_schedule?(series, date)
      margin = RecurringTransaction::Schedule::WEEKEND_MARGIN
      series.schedule.occurrence_pairs_between(date - margin, date + margin).any? { |pair| pair.original_due_on == date }
    end
end
