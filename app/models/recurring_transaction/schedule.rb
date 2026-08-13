class RecurringTransaction
  # All date math for a recurring transaction lives here, driven by the
  # series' recurrence_rules. A series with zero rules gets an implicit
  # "monthly on expected_day_of_month" rule, so legacy rows behave exactly as
  # they always have.
  #
  # Two families of methods coexist during the migration to occurrence-based
  # scheduling:
  #
  #   * first_occurrence_after / occurrences_between / cycle_for -- the
  #     correct, rules-based engine. New code uses these.
  #   * next_occurrence_after / next_occurrence_from_today -- legacy shims
  #     preserving the exact quirks of the code they replaced (always jumping
  #     a month past the last occurrence, skipping short months instead of
  #     clamping "from today"). They keep next_expected_date persistence
  #     byte-identical for every existing series and fall through to the
  #     correct engine for any rule shape the legacy math cannot express.
  #     The occurrence work replaces their callers and deletes them.
  class Schedule
    # How far an entry's day-of-month may drift from the expected day and
    # still count as the same occurrence.
    DAY_MATCH_TOLERANCE = 2

    # Weekend-adjusted occurrences move at most 2 days; raw generation pads
    # its range by this much so adjusted dates cannot escape a query window.
    WEEKEND_MARGIN = 3

    # first_occurrence_after gives up after this many days without a hit
    # (weekend-skip can drop many consecutive occurrences, so the search must
    # be a loop, but a bounded one).
    SEARCH_CAP_DAYS = 366 * 10

    Rule = Data.define(:frequency, :interval, :day_of_month, :weekday, :weekday_ordinal, :month_of_year)

    attr_reader :rules, :anchor_date, :weekend_adjust, :end_mode, :end_on, :end_after_count,
                :expected_day_of_month

    def self.for(recurring_transaction)
      new(
        expected_day_of_month: recurring_transaction.expected_day_of_month,
        rules: recurring_transaction.recurrence_rules.map { |rule|
          Rule.new(
            frequency: rule.frequency,
            interval: rule.interval,
            day_of_month: rule.day_of_month,
            weekday: rule.weekday,
            weekday_ordinal: rule.weekday_ordinal,
            month_of_year: rule.month_of_year
          )
        },
        anchor_date: recurring_transaction.anchor_date || recurring_transaction.last_occurrence_date,
        weekend_adjust: recurring_transaction.weekend_adjust,
        end_mode: recurring_transaction.end_mode,
        end_on: recurring_transaction.end_on,
        end_after_count: recurring_transaction.end_after_count
      )
    end

    def initialize(expected_day_of_month:, rules: [], anchor_date: nil, weekend_adjust: "none",
                   end_mode: "never", end_on: nil, end_after_count: nil)
      @expected_day_of_month = expected_day_of_month
      @rules = rules.presence || [ implicit_monthly_rule ]
      @anchor_date = anchor_date
      @weekend_adjust = weekend_adjust
      @end_mode = end_mode
      @end_on = end_on
      @end_after_count = end_after_count

      if @rules.any? { |rule| rule.interval > 1 } && @anchor_date.nil?
        raise ArgumentError, "an anchor_date is required when a rule repeats every 2 or more periods"
      end
      if @end_mode == "after_count" && @anchor_date.nil?
        raise ArgumentError, "an anchor_date is required to count occurrences from"
      end
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

    # --- The rules-based engine ---

    # Every occurrence with start_date <= date <= end_date, weekend-adjusted,
    # end-mode-truncated, sorted, deduplicated.
    def occurrences_between(start_date, end_date)
      return [] if start_date > end_date

      if end_mode == "after_count"
        lifetime_occurrences(through: end_date).select { |date| date >= start_date }
      else
        adjusted_occurrences(start_date, end_date)
      end
    end

    # First occurrence strictly after `date`, or nil when the series has
    # ended. This is the CORRECT next-date semantics; contrast the legacy
    # next_occurrence_after below.
    def first_occurrence_after(date)
      window = longest_period_days
      cursor = date + 1

      while cursor <= date + SEARCH_CAP_DAYS
        found = occurrences_between(cursor, cursor + window).first
        return found if found
        return nil if ended_before?(cursor + window)

        cursor += window + 1
      end

      nil
    end

    # The period containing `date`: from the last occurrence on-or-before it
    # (inclusive) up to the next one (exclusive). A monthly bill's cycle is
    # its billing month.
    def cycle_for(date)
      window = longest_period_days
      lookback = occurrences_between(date - window * 2, date)
      cycle_start = lookback.last || first_occurrence_after(date - window * 2 - 1)
      return nil if cycle_start.nil?

      cycle_end = first_occurrence_after(cycle_start)
      return nil if cycle_end.nil?

      cycle_start...cycle_end
    end

    # Average occurrences per year across all rules; the model turns this
    # into a monthly-equivalent amount for cadence-normalized totals.
    def occurrences_per_year
      rules.sum do |rule|
        case rule.frequency
        when "weekly"  then 365.25 / (7.0 * rule.interval)
        when "monthly" then 12.0 / rule.interval
        when "yearly"  then 1.0 / rule.interval
        end
      end
    end

    # --- Legacy shims (see class comment) ---

    def next_occurrence_after(date)
      return first_occurrence_after(date) unless legacy_monthly?

      occurrence_in_month(date.next_month)
    end

    def next_occurrence_from_today
      return first_occurrence_after(Date.current) unless legacy_monthly?

      today = Date.current

      begin
        this_month = Date.new(today.year, today.month, expected_day_of_month)
        return this_month if this_month > today
      rescue ArgumentError
        # Preserved quirk: no clamping here -- a day-31 bill skips February
        # entirely and lands on March 31.
      end

      occurrence_in_month(today.next_month)
    end

    private
      def implicit_monthly_rule
        raise ArgumentError, "a schedule needs rules or an expected_day_of_month" if expected_day_of_month.nil?

        Rule.new(frequency: "monthly", interval: 1, day_of_month: expected_day_of_month,
                 weekday: nil, weekday_ordinal: nil, month_of_year: nil)
      end

      # True for the one shape the pre-rules code could express: a single
      # monthly day-of-month rule with no interval, adjustment, or end. Only
      # these series get the preserved quirks.
      def legacy_monthly?
        rules.size == 1 &&
          rules.first.frequency == "monthly" &&
          rules.first.day_of_month.present? &&
          rules.first.day_of_month != RecurrenceRule::LAST &&
          rules.first.interval == 1 &&
          weekend_adjust == "none" &&
          end_mode == "never"
      end

      def adjusted_occurrences(start_date, end_date)
        raw = rules.flat_map { |rule| raw_occurrences(rule, start_date - WEEKEND_MARGIN, end_date + WEEKEND_MARGIN) }

        raw.filter_map { |date| adjust_for_weekend(date) }
           .uniq
           .sort
           .select { |date| date >= start_date && date <= end_date && !past_end_date?(date) }
      end

      # The series' first end_after_count occurrences, counted from the
      # anchor, up to `through`.
      def lifetime_occurrences(through:)
        adjusted_occurrences(anchor_date, [ through, anchor_date ].max).first(end_after_count)
      end

      def past_end_date?(date)
        end_mode == "on_date" && end_on.present? && date > end_on
      end

      def ended_before?(date)
        case end_mode
        when "on_date" then end_on.present? && end_on < date
        when "after_count" then lifetime_occurrences(through: date).size >= end_after_count
        else false
        end
      end

      def adjust_for_weekend(date)
        return date unless date.saturday? || date.sunday?

        case weekend_adjust
        when "skip"   then nil
        when "before" then date.saturday? ? date - 1 : date - 2
        when "after"  then date.saturday? ? date + 2 : date + 1
        else date
        end
      end

      def raw_occurrences(rule, start_date, end_date)
        case rule.frequency
        when "weekly"  then weekly_occurrences(rule, start_date, end_date)
        when "monthly" then monthly_occurrences(rule, start_date, end_date)
        when "yearly"  then yearly_occurrences(rule, start_date, end_date)
        end
      end

      # The anchor fixes WHICH week/month/year an every-N cadence fires in;
      # occurrences extend backward as well as forward so history can be
      # reconstructed (catch-up/backfill).
      def weekly_occurrences(rule, start_date, end_date)
        step = 7 * rule.interval
        reference = anchor_date || start_date
        base = reference + ((rule.weekday - reference.wday) % 7)

        first_step = ((start_date - base).to_i.to_f / step).ceil
        occurrences = []
        cursor = base + first_step * step
        while cursor <= end_date
          occurrences << cursor
          cursor += step
        end
        occurrences
      end

      def monthly_occurrences(rule, start_date, end_date)
        reference_month = month_index(anchor_date || start_date)

        occurrences = []
        month = Date.new(start_date.year, start_date.month, 1)
        while month <= end_date
          if (month_index(month) - reference_month) % rule.interval == 0
            date = date_in_month(rule, month)
            occurrences << date if date && date >= start_date && date <= end_date
          end
          month = month.next_month
        end
        occurrences
      end

      def yearly_occurrences(rule, start_date, end_date)
        reference_year = (anchor_date || start_date).year

        occurrences = []
        (start_date.year..end_date.year).each do |year|
          next unless (year - reference_year) % rule.interval == 0

          date = date_in_month(rule, Date.new(year, rule.month_of_year, 1))
          occurrences << date if date && date >= start_date && date <= end_date
        end
        occurrences
      end

      def month_index(date)
        date.year * 12 + date.month
      end

      # The rule's day within the given month: a day-of-month (clamped into
      # short months, -1 meaning the last day) or an nth weekday (nil when
      # the month has no 5th such weekday, skipping that month).
      def date_in_month(rule, month_start)
        if rule.day_of_month.present?
          return month_start.end_of_month if rule.day_of_month == RecurrenceRule::LAST

          begin
            Date.new(month_start.year, month_start.month, rule.day_of_month)
          rescue ArgumentError
            month_start.end_of_month
          end
        else
          nth_weekday_in_month(month_start, rule.weekday, rule.weekday_ordinal)
        end
      end

      def nth_weekday_in_month(month_start, weekday, ordinal)
        if ordinal == RecurrenceRule::LAST
          month_end = month_start.end_of_month
          month_end - ((month_end.wday - weekday) % 7)
        else
          first = month_start + ((weekday - month_start.wday) % 7)
          candidate = first + 7 * (ordinal - 1)
          candidate.month == month_start.month ? candidate : nil
        end
      end

      # The longest gap between two consecutive occurrences of any rule, in
      # days, padded. Used to size search windows.
      def longest_period_days
        rules.map { |rule|
          case rule.frequency
          when "weekly"  then 7 * rule.interval
          when "monthly" then 31 * rule.interval
          when "yearly"  then 366 * rule.interval
          end
        }.max + 40
      end

      # The expected day within the given month, clamped to the month's end.
      # Serves the legacy shims only.
      def occurrence_in_month(date)
        Date.new(date.year, date.month, expected_day_of_month)
      rescue ArgumentError
        date.end_of_month
      end
  end
end
