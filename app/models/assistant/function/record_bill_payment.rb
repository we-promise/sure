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

  AMOUNT_HINT = "Check the occurrence's remaining amount via get_bill_details and retry once with a valid amount."

  def call(params = {})
    return recurring_disabled_result if recurring_disabled?

    series, error = find_writable_series(params["bill_id"])
    return error if error

    # Settling means the amount was not provided at all. A present-but-blank
    # amount is malformed input, not a request to settle: it falls through to
    # parse_amount and is rejected there.
    settling = params["amount"].nil?

    occurrence, occurrence_error = resolve_occurrence(
      series, params["occurrence_due_on"], settling: settling
    )
    return occurrence_error if occurrence_error

    paid_on = parse_paid_on(params["paid_on"])
    return paid_on if paid_on.is_a?(Hash)

    allocator = RecurringTransaction::Allocator.new(occurrence)

    if settling
      allocator.mark_paid!(paid_on: paid_on)
    else
      amount = parse_amount(params["amount"])
      return amount if amount.is_a?(Hash)

      # Friendly pre-check only: the authoritative remainder guard runs inside
      # Allocator#allocate! under the occurrence lock, where two concurrent
      # calls cannot both read the same stale capacity.
      capacity = check_capacity(occurrence, amount)
      return capacity if capacity

      allocator.allocate!(amount: amount, paid_on: paid_on, source: "user_created", cap_at_remaining: true)
    end

    { recorded: true, bill: series.display_name, occurrence: serialize_occurrence(occurrence.reload).merge(status: occurrence.status) }
  rescue RecurringTransaction::Allocator::OverAllocationError, ActiveRecord::RecordInvalid, ArgumentError => e
    {
      error: e.message,
      hint: "Check the occurrence's remaining amount via get_bill_details and retry once with a valid amount."
    }
  end

  private
    def resolve_occurrence(series, due_on, settling: false)
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

        # Settling without naming a cycle means the one that is owed now. After
        # a cycle is paid the next one becomes current, so a retried settle used
        # to fall straight through and close NEXT month too: two identical
        # requests, two cycles paid, no money moved for either.
        #
        # Only the settle path is guarded. Sending an explicit amount toward the
        # next open cycle is a deliberate act with its own test, and an amount
        # is exactly what a blind retry of a settle does not carry.
        if settling && occurrence&.scheduled? && occurrence.derived_state == :upcoming
          return [ nil, {
            error: "#{series.display_name} has nothing owed right now",
            hint: "Its next cycle is due #{occurrence.due_on.iso8601} and is not owed yet. " \
                  "If you really mean to pay ahead, retry with occurrence_due_on set to that date."
          } ]
        end

        return [ occurrence, nil ] if occurrence&.scheduled?

        [ nil, {
          error: "#{series.display_name} has no open occurrence to pay",
          hint: "Nothing is currently owed on this bill. Use get_bill_details to see its state."
        } ]
      end
    end

    # BigDecimal parses "Infinity" and "NaN"; the tool caller does not enforce
    # params_schema, so both are rejected here rather than escaping as a raw
    # PG::NumericValueOutOfRange. A negative was previously flipped with .abs,
    # which turned a confused model into a silent payment.
    def parse_amount(value)
      magnitude = begin
        BigDecimal(value.to_s)
      rescue ArgumentError
        nil
      end

      return { error: "amount is not a number", hint: AMOUNT_HINT } if magnitude.nil? || !magnitude.finite?
      return { error: "amount must be greater than zero", hint: AMOUNT_HINT } unless magnitude.positive?

      magnitude
    end

    # An occurrence cannot absorb more than it owes. The allocator only ever
    # capped payments attached to a bank entry, so every payment recorded
    # through this tool was capped by nothing: two identical $1,500 retries
    # settled a $2,000 bill at $3,000, and $999,999 was accepted outright. The
    # error hint has always promised this ceiling; now it exists.
    def check_capacity(occurrence, amount)
      remaining = occurrence.remaining_amount
      return nil if amount <= remaining

      {
        error: "#{Money.new(amount, occurrence.currency).format} is more than the " \
               "#{occurrence.remaining_amount_money.format} still owed on the cycle due " \
               "#{occurrence.due_on.iso8601}",
        hint: "Record at most the remaining amount. If this payment was already recorded, do not retry."
      }
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
