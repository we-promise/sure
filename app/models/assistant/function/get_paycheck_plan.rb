class Assistant::Function::GetPaycheckPlan < Assistant::Function
  include Assistant::Function::BillsSupport

  class << self
    def name
      "get_paycheck_plan"
    end

    def description
      <<~INSTRUCTIONS
        Get the user's income plan: time sliced into pay periods by their declared income
        schedule, with each period showing what is due before the next payday, what must
        stay reserved for bigger bills due later, and what is genuinely safe to spend
        (income - due - reserved).

        Key concepts:
        - Only income the user declared defines paydays. Detected bank inflows never do.
        - A "bridge" period is the window between today and the next payday: nothing
          arrives in it, so what it needs must come from cash already in hand.
        - "reserved" is the part of a later bill that its own paycheck cannot cover,
          set aside out of an earlier one -- rent that outgrows one paycheck reserves
          the difference from the paychecks just before it. A bill its own paycheck
          covers reserves nothing.
        - A "short" period's obligations exceed its income by "shortfall".

        This answers "can I afford X before my next paycheck" and "which paycheck does
        this bill come out of".
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
        periods_limit: {
          type: "integer", minimum: 1, maximum: 6,
          description: "How many pay periods to plan (default 3)."
        }
      }
    )
  end

  def call(params = {})
    return recurring_disabled_result if recurring_disabled?

    planner = RecurringTransaction::PaycheckPlanner.new(family, user: user)
    limit = (Integer(params["periods_limit"].to_s, exception: false) || 3).clamp(1, 6)
    periods = planner.plan(periods_limit: limit)

    if periods.blank?
      return {
        error: "No declared income schedule",
        hint: "Only manually declared income defines paydays; detected inflows never do. Suggest the user adds their income under Bills -> Income plan. Do not infer paydays from transaction data."
      }
    end

    {
      as_of_date: Date.current.iso8601,
      family_currency: family.currency,
      unconvertible_count: planner.unconvertible_count,
      periods: periods.map { |period| serialize_period(period) }
    }.merge(unconfirmed_exclusion)
  end

  private
    # The planner counts confirmed series only, which is the right call: a
    # detection nobody has acknowledged is not yet an obligation. But every
    # figure here is spending headroom, so dropping them without a word makes
    # the plan read more comfortable than it is. Name what was left out and let
    # the assistant caveat the number instead of overstating it.
    def unconfirmed_exclusion
      # Spend only. This counted every suggested series including income, and
      # then asserted that safe-to-spend is an upper bound. An excluded
      # paycheck pushes it the other way, so a family whose only pending
      # detection was income was told its headroom was overstated when the
      # opposite was true.
      count = accessible_series.suggested.where.not(bill_type: "income").count
      return {} if count.zero?

      {
        unconfirmed_excluded: {
          count: count,
          note: "#{count} detected series are still awaiting confirmation and are NOT counted in " \
                "these figures, so safe-to-spend is an upper bound. Say so when presenting it. " \
                "Call get_bills with status: suggested to list them."
        }
      }
    end

    # A bridge window earns nothing, so income minus obligations is negative
    # whenever a bill falls in it. Reporting that as safe_after_bills told the
    # assistant the user was underwater on a window that is funded from cash
    # already in the bank, and it read as a deficit next to short: false.
    #
    # For a bridge, headroom is cash minus what is due out of it. When the
    # balance cannot be read there is no honest number, so the key is OMITTED
    # from the payload (serialize_period compacts nils away), which the
    # unreadable-balance test pins on purpose: an absent key cannot be read
    # aloud as a figure.
    def safe_after_bills(period)
      return period.cash_after_obligations.nil? ? nil : fmt(period.cash_after_obligations) if period.bridge?

      # A short window has no safe amount. The page prints the shortfall under
      # its own label and never renders a negative "safe"; the tool emitted
      # -$6,300.00 as safe_after_bills, which read aloud is not a sentence
      # anybody means. short and shortfall carry that case already.
      return nil if period.short?

      fmt(period.remaining)
    end

    def serialize_period(period)
      {
        starts_on: period.starts_on.iso8601,
        ends_on: period.ends_on.iso8601,
        bridge: period.bridge?,
        income: fmt(period.income),
        income_sources: period.income_sources,
        due_total: fmt(period.due_total),
        reserved_total: fmt(period.reserved_total),
        safe_after_bills: safe_after_bills(period),
        cash_on_hand: (period.bridge? && period.cash_on_hand.present? ? fmt(period.cash_on_hand) : nil),
        short: period.short?,
        shortfall: period.short? ? fmt(period.shortfall) : nil,
        bills_due: period.items_due.map { |item| serialize_item(item) },
        reserved_for_later: period.items_reserved.map { |item| serialize_item(item) },
        largest_obligation: largest_obligation(period)
      }.compact
    end

    def serialize_item(item)
      {
        name: item.occurrence.recurring_transaction.display_name,
        due_on: item.occurrence.due_on.iso8601,
        this_period_share: fmt(item.share),
        whole_obligation_remaining: fmt(item.remaining_total)
      }
    end

    def largest_obligation(period)
      item = period.largest_obligation
      return nil if item.nil?

      {
        name: item.occurrence.recurring_transaction.display_name,
        remaining_total: fmt(item.remaining_total)
      }
    end

    # Planner sums over an empty side come back as bare zero, not Money.
    def fmt(value)
      value.respond_to?(:format) ? value.format : Money.new(value, family.currency).format
    end
end
