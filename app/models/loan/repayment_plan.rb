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

    def initialize(repayments)
      @repayments = Array(repayments)
    end

    def self.for(scenario)
      new(scenario&.extra_repayments.to_a)
    end

    # Change points in [from_date, to_date) -- HALF-OPEN, deliberately.
    #
    # The simulator walks contiguous periods and asks each one for its changes,
    # and its normaliser matches dates inclusively at BOTH ends. A repayment
    # landing exactly on a payment date would therefore be handed to the period
    # that closes on it AND the period that opens on it, and applied twice --
    # a delta double-counted, halving the modelled balance at that point.
    # (Rates and offsets are levels, not deltas, so the same inclusivity is
    # harmless for them; that asymmetry is why this is fixed here rather than
    # in the shared normaliser.)
    #
    # Excluding the closing boundary puts each date in exactly one period, and
    # the one it lands in is the period that OPENS on it -- which is also what
    # C6 asks for and how the accrual windows are cut (C7).
    def change_points(from_date, to_date)
      return [] if from_date.nil? || to_date.nil? || from_date >= to_date

      totals = Hash.new { |hash, key| hash[key] = BigDecimal("0") }

      @repayments.each do |repayment|
        dates_for(repayment, from_date, to_date).each do |date|
          totals[date] += BigDecimal(repayment.amount.to_s)
        end
      end

      totals.sort.map { |date, amount| { date: date, amount: amount } }
    end

    private

      def dates_for(repayment, from_date, to_date)
        if repayment.one_off?
          date = repayment.occurs_on
          return [] if date.blank? || date < from_date || date >= to_date

          [ date ]
        else
          recurring_dates(repayment, from_date, to_date)
        end
      end

      def recurring_dates(repayment, from_date, to_date)
        rule = FREQUENCY_RULES[repayment.frequency]
        return [] if rule.nil?

        window_start = [ from_date, repayment.starts_on ].compact.max
        window_end = [ to_date - 1, repayment.ends_on ].compact.min
        return [] if window_start > window_end

        anchor = repayment.starts_on || from_date

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
