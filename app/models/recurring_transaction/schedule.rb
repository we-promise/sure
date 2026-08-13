class RecurringTransaction
  # All date math for a recurring transaction lives here. The model, the
  # Identifier and the Cleaner previously carried three separate copies of
  # next-date calculation; this PORO is the single owner.
  #
  # Monthly-only at this stage, because `expected_day_of_month` is all the
  # schema can express. The public surface is deliberately wider than the
  # monthly case needs (`occurrences_between`, `cycle_for`) so the frequency
  # work extends this class instead of scattering date logic again.
  class Schedule
    attr_reader :expected_day_of_month

    # How far an entry's day-of-month may drift from the expected day and
    # still count as the same occurrence.
    DAY_MATCH_TOLERANCE = 2

    def self.for(recurring_transaction)
      new(expected_day_of_month: recurring_transaction.expected_day_of_month)
    end

    # Distance between two days on the 31-day calendar circle, so the 30th
    # and the 1st are two days apart, not twenty-nine.
    def self.circular_day_distance(day1, day2)
      linear = (day1 - day2).abs
      [ linear, 31 - linear ].min
    end

    # SQL fragment selecting entries whose day-of-month lies within
    # DAY_MATCH_TOLERANCE of :expected_day on the circular calendar, with the
    # expected day clamped into short months (a day-31 bill matches Feb 28).
    # Callers bind :expected_day and :tolerance.
    def self.day_window_sql
      clamped = "LEAST(:expected_day, EXTRACT(DAY FROM (DATE_TRUNC('month', entries.date) + INTERVAL '1 month' - INTERVAL '1 day')))"
      distance = "ABS(EXTRACT(DAY FROM entries.date) - #{clamped})"
      "LEAST(#{distance}, 31 - #{distance}) <= :tolerance"
    end

    # Ruby-side twin of day_window_sql for code that already holds the entry.
    def matches_day?(date)
      clamped_expected = [ expected_day_of_month, date.end_of_month.day ].min
      self.class.circular_day_distance(date.day, clamped_expected) <= DAY_MATCH_TOLERANCE
    end

    def initialize(expected_day_of_month:)
      @expected_day_of_month = expected_day_of_month
    end

    # The next occurrence strictly after `date`. Note the deliberate quirk
    # this preserves from the code it replaced: counting from an occurrence
    # date always jumps to the following month, even when this month's
    # expected day is still ahead (see ScheduleTest's early-payer case).
    def next_occurrence_after(date)
      occurrence_in_month(date.next_month)
    end

    # The next occurrence strictly after today, allowing this month's
    # expected day when it has not passed yet. This is the correct behavior
    # for "when is this due next" questions asked from the present.
    def next_occurrence_from_today
      today = Date.current

      begin
        this_month = Date.new(today.year, today.month, expected_day_of_month)
        return this_month if this_month > today
      rescue ArgumentError
        # Day doesn't exist in this month (e.g., 31st in February). Preserved
        # quirk: no clamping here -- February is skipped and the next real
        # occurrence of that day is returned.
      end

      next_occurrence_after(today)
    end

    # Every occurrence with start_date <= date <= end_date, in order. One per
    # month today; the frequency work makes this the load-bearing method for
    # weekly and semimonthly cadences.
    def occurrences_between(start_date, end_date)
      return [] if start_date > end_date

      occurrences = []
      cursor = occurrence_in_month(start_date)
      cursor = occurrence_in_month(start_date.next_month) if cursor < start_date

      while cursor <= end_date
        occurrences << cursor
        cursor = occurrence_in_month(cursor.next_month)
      end

      occurrences
    end

    # The period containing `date` -- from one occurrence (inclusive) up to
    # the next (exclusive). A monthly bill's cycle is its billing month.
    def cycle_for(date)
      this_month = occurrence_in_month(date)

      if date >= this_month
        this_month...occurrence_in_month(this_month.next_month)
      else
        occurrence_in_month(date.prev_month)...this_month
      end
    end

    private
      # The expected day within the given month, clamped to the month's end
      # when the day does not exist (Jan 31 -> Feb 28, or Feb 29 in a leap
      # year).
      def occurrence_in_month(date)
        Date.new(date.year, date.month, expected_day_of_month)
      rescue ArgumentError
        date.end_of_month
      end
  end
end
