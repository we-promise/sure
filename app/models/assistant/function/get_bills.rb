class Assistant::Function::GetBills < Assistant::Function
  include Assistant::Function::BillsSupport

  MAX_RESULTS = 100

  class << self
    def name
      "get_bills"
    end

    def description
      <<~INSTRUCTIONS
        Get the user's bills, subscriptions and other recurring obligations, each with its
        current occurrence's payment state.

        Key concepts:
        - status is the series lifecycle: "active" (default), "suggested" (detected from
          bank data, awaiting the user's confirmation -- not yet a real bill),
          "paused" (set aside by the user), "ended" (dismissed or finished), "all".
        - payment_state filters on the CURRENT occurrence instead: "overdue", "due",
          "upcoming", "partial" (partly paid), "paid".
        - bill_type "income" is a declared income schedule (paycheck), not an obligation.
          Amounts are always positive magnitudes; bill_type carries the direction.
        - totals exclude income and transfers (a transfer moves money, it is not spend),
          and normalize each bill to a monthly equivalent whatever its cadence.

        Use get_bill_details for one bill's full history and configuration.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [],
      properties: {
        status: {
          type: "string",
          enum: %w[active suggested paused ended all],
          description: "Series lifecycle filter. Defaults to active."
        },
        payment_state: {
          type: "string",
          enum: %w[overdue due upcoming partial paid],
          description: "Filter by the current occurrence's payment state (applied after the status filter)."
        },
        bill_type: {
          type: "string",
          enum: RecurringTransaction.bill_types.keys,
          description: "Filter by kind of recurring obligation."
        },
        search: { type: "string", description: "Substring match on the bill or merchant name." },
        due_within_days: {
          type: "integer", minimum: 1, maximum: 365,
          description: "Only bills whose next due date falls within this many days."
        }
      }
    )
  end

  def call(params = {})
    return recurring_disabled_result if recurring_disabled?

    # recurrence_rules included because serialization reads the schedule
    # (frequency, next due date); without it every series costs one query.
    scope = accessible_series.includes(:merchant, :account, :destination_account, :category,
                                       :recurring_occurrences, :recurrence_rules)
    invalid = reject_unknown_filters(params)
    return invalid if invalid

    scope = apply_status_filter(scope, params["status"])

    if (bill_type = params["bill_type"]).present?
      scope = scope.where(bill_type: bill_type)
    end

    if (search = params["search"].to_s).present?
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(search)}%"
      scope = scope.left_joins(:merchant)
                   .where("recurring_transactions.name ILIKE :p OR merchants.name ILIKE :p", p: pattern)
    end

    rows = scope.order(next_expected_date: :asc).to_a
    currents = rows.index_with { |series| current_occurrence_from_loaded(series) }
    preload_allocation_sums(currents.values)

    # Integer(..., exception: false): MCP clients send whatever they like. A
    # filter that silently answers a different question than it was asked is
    # worse than an error, so out-of-range values are rejected, not adjusted.
    if params["due_within_days"].present?
      days = Integer(params["due_within_days"].to_s, exception: false)
      unless days&.between?(1, 365)
        return {
          error: "due_within_days must be a whole number between 1 and 365",
          hint: "Retry once with a value in that range, or omit it."
        }
      end

      horizon = Date.current + days
      rows = rows.select { |series| series.next_due_date.present? && series.next_due_date <= horizon }
    end

    if (state = params["payment_state"]).present?
      rows = rows.select { |series| payment_state_matches?(currents[series], state) }
    end

    shown = rows.first(MAX_RESULTS)

    {
      as_of_date: Date.current.iso8601,
      total_results: rows.size,
      truncated: rows.size > shown.size,
      family_currency: family.currency,
      bills: shown.map { |series| serialize_series(series).merge(current_occurrence: serialize_occurrence(currents[series])) },
      totals: totals_over(rows, currents)
    }.merge(rows.empty? ? { hint: other_status_hint(params) }.compact : {})
  end

  private
    PAYMENT_STATES = %w[overdue due upcoming partial paid].freeze

    # strict_mode? is false and MCP clients bypass provider validation
    # entirely, so out-of-schema values arrive here routinely. Each one used to
    # fail differently and silently: an unknown status was coerced to active,
    # an unknown bill_type dropped its filter so "subscriptions" (plural)
    # answered with rent and a car loan totalled as subscriptions, and an
    # unknown payment_state matched nothing and read as an empty family.
    #
    # A value the caller believes in is worth an error. Guessing at it produces
    # a confident answer about the wrong bills.
    def reject_unknown_filters(params)
      unknown_value(params["status"], STATUS_VOCABULARY.keys + [ "all" ], "status") ||
        unknown_value(params["bill_type"], RecurringTransaction.bill_types.keys, "bill_type") ||
        unknown_value(params["payment_state"], PAYMENT_STATES, "payment_state")
    end

    def unknown_value(value, allowed, field)
      return nil if value.blank? || value.to_s.in?(allowed)

      {
        error: "#{value} is not a valid #{field}",
        hint: "Valid values: #{allowed.join(', ')}."
      }
    end

    def apply_status_filter(scope, status)
      return scope if status == "all"

      scope.where(status: STATUS_VOCABULARY.fetch(status.presence || "active", STATUS_VOCABULARY.fetch("active")))
    end

    # An empty answer is ambiguous: it reads as "you have none of these" when it
    # usually means "every one you have sits under a status this call filtered
    # out". Detection parks new series in `suggested`, so asking about
    # subscriptions on a family that has confirmed none answers zero results and
    # a $0 total, which is worse than no answer at all. Only runs when nothing
    # matched, so the normal path costs no extra query.
    def other_status_hint(params)
      # Only the status filter can be pointed elsewhere. When something else
      # emptied the result, saying "nothing matched status active" is simply
      # false, and the retry it prescribes returns empty again with no hint at
      # all, because this method early-returns on status: all.
      narrowing = params.values_at("payment_state", "search", "due_within_days").compact_blank
      return if narrowing.any?

      requested = params["status"].presence || "active"
      return if requested == "all"

      known = STATUS_VOCABULARY.fetch(requested, STATUS_VOCABULARY.fetch("active"))
      scope = accessible_series.where.not(status: known)

      if (bill_type = params["bill_type"]).presence_in(RecurringTransaction.bill_types.keys)
        scope = scope.where(bill_type: bill_type)
      end

      elsewhere = scope.group(:status).count
      return if elsewhere.empty?

      summary = elsewhere.sort_by { |_status, count| -count }
                         .map { |status, count| "#{count} #{status}" }
                         .join(", ")

      "Nothing matched status #{requested}, but this family has #{summary}. Call get_bills " \
        "again with that status, or status: all, before telling the user they have none."
    end

    def payment_state_matches?(occurrence, state)
      return false if occurrence.nil?

      case state
      when "overdue" then occurrence.overdue?
      when "due" then occurrence.derived_state == :due
      when "upcoming" then occurrence.derived_state == :upcoming
      when "partial" then occurrence.partially_paid?
      when "paid" then occurrence.paid?
      else false
      end
    end

    # Over the FULL filtered set, not the shown page, so a truncated list
    # still reports honest totals.
    def totals_over(rows, currents)
      spend = rows.select { |series| series.active? && spend_series?(series) }

      monthly = spend.group_by(&:currency).to_h do |currency, group|
        total = group.sum(Money.new(0, currency)) { |series| series.monthly_equivalent_amount.abs }
        [ currency, total.format ]
      end

      {
        active_count: rows.count(&:active?),
        overdue_count: rows.count { |series| currents[series]&.overdue? },
        active_monthly_equivalent_by_currency: monthly
      }
    end
end
