class Assistant::Function::RecordBillPayment < Assistant::Function
  include Assistant::Function::BillsSupport

  class << self
    def name
      "record_bill_payment"
    end

    def description
      <<~INSTRUCTIONS
        Record a payment against a bill's open occurrence, or settle it in full.

        - Omit amount to settle the occurrence completely (the remainder is recorded
          as a manual payment with no transaction attached).
        - Pass amount for a partial payment; the occurrence stays open until payments
          cover the expected amount.
        - occurrence_due_on picks a specific open occurrence by its due date; omitted,
          the current (earliest open) occurrence is used.
        - Linking a payment to a specific bank transaction is not possible here: the
          app's matching engine and its review queue own that, so suggest the user
          confirms matches on the Bills page instead.

        Confirm with the user before recording anything.
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
        occurrence_due_on: { type: "string", description: "Due date (YYYY-MM-DD) of the open occurrence to pay. Defaults to the current one." },
        amount: { type: "number", minimum: 0.01, description: "Partial payment magnitude. Omit to settle in full." },
        paid_on: { type: "string", description: "When it was paid, YYYY-MM-DD. Defaults to today." }
      }
    )
  end

  def call(params = {})
    return recurring_disabled_result if recurring_disabled?

    series, error = find_series(params["bill_id"])
    return error if error

    occurrence, occurrence_error = resolve_occurrence(series, params["occurrence_due_on"])
    return occurrence_error if occurrence_error

    paid_on = parse_paid_on(params["paid_on"])
    return paid_on if paid_on.is_a?(Hash)

    allocator = RecurringTransaction::Allocator.new(occurrence)

    if params["amount"].present?
      allocator.allocate!(amount: BigDecimal(params["amount"].to_s).abs, paid_on: paid_on, source: "user_created")
    else
      allocator.mark_paid!(paid_on: paid_on)
    end

    { recorded: true, bill: series.display_name, occurrence: serialize_occurrence(occurrence.reload).merge(status: occurrence.status) }
  rescue RecurringTransaction::Allocator::OverAllocationError, ActiveRecord::RecordInvalid, ArgumentError => e
    {
      error: e.message,
      hint: "Check the occurrence's remaining amount via get_bill_details and retry once with a valid amount."
    }
  end

  private
    def resolve_occurrence(series, due_on)
      if due_on.present?
        date = begin
          Date.parse(due_on.to_s)
        rescue Date::Error
          nil
        end

        if date.nil?
          return [ nil, { error: "occurrence_due_on is not a valid date", hint: "Use YYYY-MM-DD." } ]
        end

        occurrence = series.recurring_occurrences.open_status.find_by(due_on: date)
        return [ occurrence, nil ] if occurrence

        [ nil, {
          error: "No open occurrence of #{series.display_name} is due on #{date.iso8601}",
          hint: "Open due dates: #{open_due_dates(series)}. Retry once with one of them, or omit occurrence_due_on."
        } ]
      else
        occurrence = series.current_occurrence
        return [ occurrence, nil ] if occurrence&.scheduled?

        [ nil, {
          error: "#{series.display_name} has no open occurrence to pay",
          hint: "Nothing is currently owed on this bill. Use get_bill_details to see its state."
        } ]
      end
    end

    def open_due_dates(series)
      dates = series.recurring_occurrences.open_status.order(:due_on).limit(6).pluck(:due_on)
      dates.any? ? dates.map(&:iso8601).join(", ") : "none"
    end

    def parse_paid_on(value)
      return Date.current if value.blank?

      Date.parse(value.to_s)
    rescue Date::Error
      { error: "paid_on is not a valid date", hint: "Use YYYY-MM-DD." }
    end
end
