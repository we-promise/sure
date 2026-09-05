class Assistant::Function::ProjectCashBalance < Assistant::Function
  MAX_EVENTS = 60

  class << self
    def name
      "project_cash_balance"
    end

    def description
      <<~INSTRUCTIONS
        Projects the user's cash balance forward day by day, INCLUDING their
        declared income, and reports where it bottoms out and which thresholds
        it crosses.

        Use this for "will I make it to the end of the month", "when am I
        tightest", "can I afford X before payday". Prefer it over reasoning from
        get_transactions: the arithmetic here is deterministic and already
        accounts for known bills, known income and any arranged overdraft.

        How to read the result:
        - `low_point` is the worst day and its balance. Quote the date, not just
          the number: "tightest on the 27th at X" is actionable, a bare negative
          figure is not.
        - `breaches` lists only the thresholds actually crossed. `zero` is
          crossing into overdraft; `overdraft_limit` is crossing the arranged
          facility, which is the one that costs money. A threshold that is
          absent was never reached.
        - `events` are the dated bills and income driving the shape. The rest of
          the spending is a smoothed daily baseline with no date of its own.
        - `warnings` is NOT optional reading. In particular, when no income has
          been declared the projection contains no salary at all, and its low
          point is a floor rather than a forecast. Say so before quoting it.
        - `assumptions` says which accounts were included and what the daily
          baseline was. A projection presented without them overstates how much
          is known.

        Never present the low point as a prediction of what will happen. It is
        what follows from the bills and income currently on record.
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
        horizon_days: {
          type: "integer",
          minimum: 1,
          maximum: Cashflow::Projection::MAX_HORIZON_DAYS,
          description: "How many days ahead to project (defaults to #{Cashflow::Projection::DEFAULT_HORIZON_DAYS})"
        },
        account_ids: {
          type: "array",
          items: { type: "string" },
          description: "Restrict to these cash accounts (from get_accounts). Defaults to all of them."
        },
        thresholds: {
          type: "array",
          items: { type: "number" },
          description: "Extra balance levels to flag, e.g. -400. Zero and any recorded overdraft limit are always checked."
        },
        include_daily_series: {
          type: "boolean",
          description: "Include the full day-by-day balance series (defaults to true). Set false to save tokens when only the low point matters."
        }
      }
    )
  end

  def call(params = {})
    projection = build_projection(params)

    payload = {
      as_of_date: Date.current,
      horizon_days: projection.horizon_days,
      currency: family.currency,
      starting_balance: projection.starting_balance,
      starting_balance_formatted: money(projection.starting_balance),
      low_point: serialize_low_point(projection),
      breaches: projection.breaches.map { |breach| serialize_breach(breach) },
      events: serialize_events(projection),
      assumptions: projection.assumptions,
      warnings: projection.warnings
    }

    payload[:daily_balances] = serialize_series(projection) unless params["include_daily_series"] == false
    payload
  end

  private
    def build_projection(params)
      Cashflow::Projection.new(
        family,
        user: user,
        horizon_days: params["horizon_days"] || Cashflow::Projection::DEFAULT_HORIZON_DAYS,
        account_ids: params["account_ids"].presence,
        extra_thresholds: Array(params["thresholds"]).map(&:to_d)
      )
    end

    def serialize_low_point(projection)
      low = projection.low_point

      {
        date: low.date,
        balance: low.balance,
        balance_formatted: money(low.balance),
        days_from_now: (low.date - Date.current).to_i
      }
    end

    def serialize_breach(breach)
      {
        threshold_label: breach.label,
        threshold: breach.threshold,
        first_crossed_on: breach.first_date,
        days_below: breach.days_below,
        deepest_on: breach.deepest_date,
        deepest_balance: breach.deepest_balance,
        deepest_balance_formatted: money(breach.deepest_balance)
      }
    end

    # Only the dated movements inside the horizon, capped so a weekly-bill-heavy
    # family cannot blow the response up. Truncation is reported rather than
    # silent, because a missing bill reads as a rosier projection.
    def serialize_events(projection)
      events = projection.events.select { |event| event.date <= projection.end_date }
      shown = events.first(MAX_EVENTS)

      payload = shown.map do |event|
        {
          date: event.date,
          label: event.label,
          amount: event.amount,
          direction: event.direction == :in ? "in" : "out"
        }
      end

      return payload if events.size <= MAX_EVENTS

      payload + [ { note: "#{events.size - MAX_EVENTS} further events are not listed, but ARE counted in the balances." } ]
    end

    # Compact form: one start date and a flat array, the same shape
    # get_accounts uses for balance history, instead of a date on every row.
    def serialize_series(projection)
      {
        start_date: projection.start_date,
        end_date: projection.end_date,
        interval: "1 day",
        currency: family.currency,
        values: projection.days.map { |day| day.closing_balance.to_f }
      }
    end

    def money(amount)
      Money.new(amount, family.currency).format
    end
end
