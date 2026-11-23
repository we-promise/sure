class Assistant::Function::SkipBillOccurrence < Assistant::Function
  include Assistant::Function::BillsSupport

  class << self
    def name
      "skip_bill_occurrence"
    end

    def description
      <<~INSTRUCTIONS
        Mark one open occurrence of a bill as skipped: that date is no longer owed and
        drops out of what is due. The same as Skip on the Bills page.

        - Use it for a cycle that does not apply: a duplicate, a phantom date left by an
          earlier schedule, a month the service was not used.
        - occurrence_due_on is the open occurrence's due date (YYYY-MM-DD), as listed in
          get_bill_details' open_occurrences.
        - Payments already recorded on it are kept. A skipped occurrence can be reopened
          on the Bills page.
        - Not for a paid cycle: record_bill_payment settles one instead.

        Confirm with the user before skipping anything.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[bill_id occurrence_due_on],
      properties: {
        bill_id: { type: "string", description: "The bill's id, exactly as returned by get_bills." },
        occurrence_due_on: { type: "string", description: "Due date (YYYY-MM-DD) of the open occurrence to skip." }
      }
    )
  end

  def call(params = {})
    return recurring_disabled_result if recurring_disabled?

    series, error = find_writable_series(params["bill_id"])
    return error if error

    date = strict_date(params["occurrence_due_on"])
    return { error: "occurrence_due_on is not a valid date", hint: "Use YYYY-MM-DD." } if date.nil?

    occurrences = series.recurring_occurrences.where(due_on: date)
    occurrence = occurrences.open_status.first

    if occurrence.nil?
      closed = occurrences.first
      return closed_error(series, closed) if closed

      return {
        error: "No occurrence of #{series.display_name} is due on #{date.iso8601}",
        hint: "Open due dates: #{open_due_dates(series)}. Retry once with one of them."
      }
    end

    occurrence.skip!

    {
      skipped: true,
      bill: series.display_name,
      occurrence: serialize_occurrence(occurrence.reload).merge(status: occurrence.status)
    }
  end

  private
    # A retried skip lands here, so it says the work is done rather than
    # inviting another attempt.
    def closed_error(series, occurrence)
      {
        error: "The occurrence of #{series.display_name} due #{occurrence.due_on.iso8601} is already #{occurrence.status}",
        hint: "Nothing to skip. Do not retry; it can be reopened on the Bills page."
      }
    end

    def open_due_dates(series)
      dates = series.recurring_occurrences.open_status.order(:due_on).limit(6).pluck(:due_on)
      dates.any? ? dates.map(&:iso8601).join(", ") : "none"
    end
end
