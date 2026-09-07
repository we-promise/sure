class Loan
  # Materialises a scenario's extra repayments into per-date amounts the
  # simulator can consume through its `extra_for` resolver.
  #
  # Contract C6 -- EXACT DATES. A repayment takes effect at the end of its own
  # effective date; the balance drops that day and subsequent days accrue on
  # it. Payment dates never defer it. Recurrence therefore materialises to real
  # dates and never to a monthly-equivalent figure: $500 weekly is 52 balance
  # reductions a year, not 12 of $2,166.67, and the interest difference between
  # those two is the entire reason someone models a weekly repayment.
  #
  # Recurrence resolution is DELEGATED to RecurringTransaction::Schedule, whose
  # constructor takes plain keywords and needs no RecurringTransaction. There
  # is no second recurrence engine here, and there should not be one.
  class RepaymentPlan
    # Cadences this feature offers, expressed in the terms the shared schedule
    # already understands. Fortnightly and quarterly are intervals on weekly
    # and monthly rather than new frequencies -- teaching the shared engine two
    # new words for periods it can already express would be a change to an
    # unrelated, heavily used subsystem for no gain.
    FREQUENCY_RULES = {
      "weekly" => { frequency: "weekly", multiplier: 1 },
      "fortnightly" => { frequency: "weekly", multiplier: 2 },
      "monthly" => { frequency: "monthly", multiplier: 1 },
      "quarterly" => { frequency: "monthly", multiplier: 3 },
      "yearly" => { frequency: "yearly", multiplier: 1 }
    }.freeze

    # `closes_on` is the last payment date in the schedule the caller will walk.
    # The final window is closed at its end; every other window is half-open.
    # Without it a repayment dated on the final payment date falls in NO window
    # and is silently dropped -- measured at 0 of 24 windows (cubic, #83).
    def initialize(repayments, closes_on: nil)
      @repayments = Array(repayments)
      @closes_on = closes_on
    end

    def self.for(scenario, closes_on: nil)
      new(scenario&.extra_repayments.to_a, closes_on: closes_on)
    end

    # Change points in [from_date, to_date) -- HALF-OPEN, deliberately -- except
    # for the final window, which is closed.
    #
    # The simulator walks contiguous periods and asks each for its changes, and
    # its normaliser matches dates inclusively at BOTH ends. A repayment landing
    # exactly on a payment date would therefore be handed to the period that
    # closes on it AND the period that opens on it, and applied twice. That is
    # not theoretical: measured on a 24-payment loan, one $5,000 repayment on a
    # payment date reduced principal by $10,000 under inclusive bounds.
    # (Rates and offsets are LEVELS, not deltas, so the same inclusivity is
    # harmless for them; that asymmetry is why this is fixed here rather than in
    # the shared normaliser.)
    #
    # Excluding the closing boundary puts each date in exactly one period -- the
    # one that OPENS on it, which is what C6 asks for and how accrual windows
    # are cut (C7). The exception is the LAST window: there is no period after
    # it to open on the final payment date, so a repayment there fell through
    # every window and vanished. That window alone closes inclusively.
    def change_points(from_date, to_date)
      return [] if from_date.nil? || to_date.nil? || from_date >= to_date

      closes_inclusively = @closes_on.present? && to_date >= @closes_on

      totals = Hash.new { |hash, key| hash[key] = BigDecimal("0") }

      @repayments.each do |repayment|
        dates_for(repayment, from_date, to_date, closes_inclusively).each do |date|
          totals[date] += BigDecimal(repayment.amount.to_s)
        end
      end

      totals.sort.map { |date, amount| { date: date, amount: amount } }
    end

    private

      def dates_for(repayment, from_date, to_date, closes_inclusively)
        upper = closes_inclusively ? to_date : to_date - 1

        if repayment.one_off?
          date = repayment.occurs_on
          return [] if date.blank? || date < from_date || date > upper

          [ date ]
        else
          recurring_dates(repayment, from_date, upper)
        end
      end

      def recurring_dates(repayment, from_date, upper)
        rule = FREQUENCY_RULES[repayment.frequency]
        return [] if rule.nil?

        # The anchor is the ROW's own start date, never the window's.
        #
        # `starts_on || from_date` re-anchored the recurrence on every call, and
        # PayoffProjection calls this once per payment period -- so a quarterly
        # repayment was re-anchored monthly and fired every month (cubic, #83).
        # `starts_on` is required for a recurring repayment at both the model
        # and DB layers, so there is no window-derived fallback to drift.
        anchor = repayment.starts_on
        return [] if anchor.blank?

        window_start = [ from_date, anchor ].max
        window_end = [ upper, repayment.ends_on ].compact.min
        return [] if window_start > window_end

        schedule_for(repayment, rule, anchor)
          .occurrences_between(window_start, window_end)
      end

      def schedule_for(repayment, rule, anchor)
        RecurringTransaction::Schedule.new(
          expected_day_of_month: anchor.day,
          rules: [
            RecurringTransaction::Schedule::Rule.new(
              frequency: rule.fetch(:frequency),
              interval: (repayment.interval || 1) * rule.fetch(:multiplier),
              # Both monthly and yearly resolve a day within a month; only
              # the weekly path uses a weekday instead.
              day_of_month: rule.fetch(:frequency) == "weekly" ? nil : anchor.day,
              weekday: rule.fetch(:frequency) == "weekly" ? anchor.wday : nil,
              weekday_ordinal: nil,
              month_of_year: rule.fetch(:frequency) == "yearly" ? anchor.month : nil
            )
          ],
          anchor_date: anchor,
          weekend_adjust: "none"
        )
      end
  end
end
