class Assistant::Function::SimulateScenarios < Assistant::Function
  MAX_SCENARIOS = 5
  MAX_MOVEMENTS = 12

  class << self
    def name
      "simulate_scenarios"
    end

    def description
      <<~INSTRUCTIONS
        Compares "what if" cash scenarios against the user's current trajectory.

        Use it before advising on a purchase, an early repayment, a new
        subscription or a change of income. Each scenario is the SAME projection
        as project_cash_balance with extra movements layered on, so the
        comparison is like for like.

        A scenario is a label plus a list of movements. A movement is an amount
        on a date, `direction` "out" for spending and "in" for money arriving,
        and optionally `repeat_monthly` with a count to model a subscription or
        an instalment plan.

        The baseline ("current") is always included, so you never have to build
        it yourself.

        What comes back per scenario: the ending balance, the dated low point,
        and which thresholds it crosses. Compare the LOW POINTS, not the ending
        balances: a scenario that ends comfortably can still cross the overdraft
        limit on the way and cost real fees.

        This tool answers what follows arithmetically. Whether the purchase is
        worth it is a judgement, and that part is yours to make with the user.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "scenarios" ],
      properties: {
        horizon_days: {
          type: "integer",
          minimum: 1,
          maximum: Cashflow::Projection::MAX_HORIZON_DAYS,
          description: "How many days ahead to compare (defaults to #{Cashflow::Projection::DEFAULT_HORIZON_DAYS})"
        },
        account_ids: {
          type: "array",
          items: { type: "string" },
          description: "Restrict to these cash accounts (from get_accounts)"
        },
        thresholds: {
          type: "array",
          items: { type: "number" },
          description: "Extra balance levels to flag in every scenario"
        },
        scenarios: {
          type: "array",
          maxItems: MAX_SCENARIOS,
          description: "Up to #{MAX_SCENARIOS} scenarios to compare against the current trajectory",
          items: {
            type: "object",
            required: [ "label", "movements" ],
            properties: {
              label: { type: "string", description: "Short name shown in the comparison, e.g. \"buy now\"" },
              movements: {
                type: "array",
                maxItems: MAX_MOVEMENTS,
                items: {
                  type: "object",
                  required: [ "date", "amount" ],
                  properties: {
                    date: { type: "string", description: "YYYY-MM-DD" },
                    amount: { type: "number", description: "Positive magnitude; the direction field carries the sign" },
                    direction: { type: "string", enum: [ "in", "out" ], description: "Defaults to out" },
                    label: { type: "string" },
                    repeat_monthly: { type: "integer", minimum: 1, maximum: 24, description: "Repeat this movement monthly, this many times in total" }
                  }
                }
              }
            }
          }
        }
      }
    )
  end

  def call(params = {})
    horizon = params["horizon_days"] || Cashflow::Projection::DEFAULT_HORIZON_DAYS
    account_ids = params["account_ids"].presence
    thresholds = Array(params["thresholds"]).map(&:to_d)

    baseline = projection_for(horizon, account_ids, thresholds, [])
    scenarios = Array(params["scenarios"]).first(MAX_SCENARIOS)

    {
      as_of_date: Date.current,
      horizon_days: baseline.horizon_days,
      currency: family.currency,
      comparison: [ summarize("current", baseline, baseline) ] +
                  scenarios.map { |scenario| summarize_scenario(scenario, baseline) },
      # Carried once rather than repeated per scenario: they are identical for
      # every scenario and would otherwise be paid for five times over.
      assumptions: baseline.assumptions,
      warnings: baseline.warnings
    }
  end

  private
    def projection_for(horizon, account_ids, thresholds, adjustments)
      Cashflow::Projection.new(
        family,
        user: user,
        horizon_days: horizon,
        account_ids: account_ids,
        extra_thresholds: thresholds,
        adjustments: adjustments
      )
    end

    # Derived from the baseline rather than rebuilt: the accounts, series,
    # occurrences and income statement are identical for every scenario in a
    # call, so they are queried once and carried.
    def summarize_scenario(scenario, baseline)
      adjustments = build_adjustments(scenario)
      projection = baseline.with_adjustments(adjustments)

      summarize(scenario["label"].to_s.presence || "scenario", projection, baseline)
        .merge(movements_applied: adjustments.size)
    end

    def summarize(label, projection, baseline)
      low = projection.low_point
      ending = projection.days.last.closing_balance

      {
        label: label,
        ending_balance: ending,
        ending_balance_formatted: money(ending),
        low_point: {
          date: low.date,
          balance: low.balance,
          balance_formatted: money(low.balance)
        },
        # The delta against the baseline low point is the number that decides
        # the question, and computing it here keeps it out of the model's head.
        low_point_delta_vs_current: (low.balance - baseline.low_point.balance).round(2),
        thresholds_crossed: projection.breaches.map do |breach|
          { threshold_label: breach.label, threshold: breach.threshold, first_crossed_on: breach.first_date, days_below: breach.days_below }
        end
      }
    end

    # A movement past the horizon is dropped rather than clamped onto the last
    # day, which would invent a cost the user never incurs inside the window.
    def build_adjustments(scenario)
      Array(scenario["movements"]).first(MAX_MOVEMENTS).flat_map do |movement|
        date = parse_date(movement["date"])
        next [] if date.nil?

        amount = movement["amount"].to_d.abs
        next [] if amount.zero?

        direction = movement["direction"].to_s == "in" ? :in : :out
        label = movement["label"].presence || scenario["label"].to_s
        repeats = (movement["repeat_monthly"] || 1).to_i.clamp(1, 24)

        (0...repeats).map do |index|
          Cashflow::Projection::Event.new(
            date: date.advance(months: index),
            label: label,
            amount: amount,
            direction: direction,
            source: "scenario"
          )
        end
      end
    end

    def parse_date(value)
      return nil if value.blank?
      Date.parse(value.to_s)
    rescue Date::Error
      nil
    end

    def money(amount)
      Money.new(amount, family.currency).format
    end
end
