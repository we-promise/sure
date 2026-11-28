class RecurringTransaction
  # Materializes Schedule output into recurring_occurrences rows. An idempotent
  # upsert keyed on (series, original_due_on), so re-running only adds missing
  # rows and never duplicates or touches existing ones.
  #
  # Only scheduled, allocation-free rows are ever deleted, and only ones that
  # are not yet due — except the date a one-payment plan was moved off.
  # Anything closed or carrying a payment is immutable history.
  class OccurrenceGenerator
    HORIZON_DAYS = 90

    attr_reader :series

    def initialize(series)
      @series = series
    end

    # From the start of the current cycle, so a recently-due unpaid occurrence
    # exists and not just future ones, through a horizon always extended far
    # enough to include the next occurrence even on annual cadences.
    def generate!(through: nil)
      return 0 unless series.active?

      schedule = series.schedule
      from = schedule.cycle_for(Date.current)&.begin || Date.current

      # A declared bill's anchor is its first obligation, so the cycle lookback
      # must not fabricate a previous-cycle debt. Auto-detected series keep the
      # cycle start, since their history predates the row.
      from = [ from, series.anchor_date ].compact.max if series.manual?

      # A one-payment plan's only date can already be past. The clamp above
      # refuses to look behind today, which would drop that only occurrence.
      if single_payment? && series.anchor_date
        from = [ from, series.anchor_date ].min
      end

      through ||= default_horizon(schedule)

      upsert_window(from, through)
    end

    # After a schedule edit: drop the re-generatable future and rebuild it under
    # the new rules. Rows with payments or closed state are kept as they were.
    def regenerate_future!(through: nil)
      removable = series.recurring_occurrences
                        .open_status
                        .where.not(id: RecurringAllocation.select(:recurring_occurrence_id))
      doomed = removable.where("due_on >= ?", Date.current)
      doomed = doomed.or(removable.where(original_due_on: single_payment_moved_from)) if single_payment_moved_from

      doomed.delete_all

      generate!(through: through)
    end

    # Materializes a past window (catch-up/backfill). The caller decides what
    # happens to uncovered past occurrences; this only creates rows.
    def backfill!(from:, through: Date.current)
      return 0 unless series.active?

      upsert_window(from, through)
    end

    private
      def single_payment?
        series.ends_after_count? && series.end_after_count == 1
      end

      # The date a one-payment plan was just moved off, whose row the new date
      # replaces even when it is past. Every other past row is an obligation
      # from an earlier schedule, which a one-date schedule cannot recreate, so
      # it stays. Converting a repeating bill to Once is not a move: the cap is
      # already stored by the time regeneration runs, so the values from before
      # the save say whether it was a single payment already.
      def single_payment_moved_from
        return unless single_payment? && series.saved_change_to_anchor_date?
        return unless series.attribute_before_last_save("end_mode") == "after_count" &&
                      series.attribute_before_last_save("end_after_count") == 1

        series.attribute_before_last_save("anchor_date")
      end

      def default_horizon(schedule)
        horizon = Date.current + HORIZON_DAYS
        next_due = schedule.first_occurrence_after(Date.current)

        # A finite plan materializes whole: an installment run is bounded by
        # definition, and seeing all N payments (and the end) is the point.
        if series.ends_after_count? && series.end_after_count.present?
          cycle_days = (365.25 / schedule.occurrences_per_year).ceil
          plan_end = (series.anchor_date || Date.current) + cycle_days * (series.end_after_count + 1)
          return [ horizon, next_due, plan_end ].compact.max
        end

        [ horizon, next_due ].compact.max
      end

      def upsert_window(from, through)
        schedule = series.schedule
        pairs = schedule.occurrence_pairs_between(from, through)
        stood_in = stood_in_for(schedule, from, through)
        pairs = pairs.reject { |pair| stood_in.include?(pair.original_due_on) }
        return 0 if pairs.empty?

        now = Time.current
        rows = pairs.map do |pair|
          {
            recurring_transaction_id: series.id,
            family_id: series.family_id,
            original_due_on: pair.original_due_on,
            due_on: pair.due_on,
            currency: series.currency,
            status: "scheduled",
            created_at: now,
            updated_at: now
          }
        end

        result = RecurringOccurrence.insert_all(rows, unique_by: "idx_recurring_occurrences_identity")
        result.rows.size
      end

      # Rows a schedule edit kept from the previous rule are paid or past-due
      # occurrences the current schedule no longer produces. Each already is
      # its cycle, so a new occurrence beside one (a due day moved by
      # detection) would be a second row for the same cycle. Each kept row
      # stands in for ONE occurrence: the nearest within half a cycle, so the
      # other day of a close semimonthly pair (the 2nd and 5th, after the 1st
      # moved to the 2nd) is still generated. A row the current schedule
      # produces never counts, so two close days of one schedule both stay.
      #
      # Returns the original_due_ons of the occurrences stood in for. Searched
      # beyond the window, so a kept row's nearest occurrence just outside it
      # is not mistaken for a farther one inside.
      def stood_in_for(schedule, from, through)
        # A Once bill is a date the user chose. Rows kept from an earlier
        # schedule are other obligations, not stand-ins for it, and a yearly
        # half cycle would let one swallow the new date. A one-payment
        # installment has no such date to protect, so its kept row still
        # stands in for the occurrence it was.
        return Set.new if single_payment? && !series.typed_installment?

        reach = half_cycle(schedule)
        nearby = schedule.occurrence_pairs_between(from - reach, through + reach)
        current = nearby.map(&:original_due_on).to_set

        series.recurring_occurrences
              .where(due_on: (from - reach)..(through + reach))
              .pluck(:original_due_on, :due_on)
              .reject { |original_due_on, _due_on| current.include?(original_due_on) }
              .filter_map do |_original_due_on, due_on|
                nearby.select { |pair| (due_on - pair.due_on).abs <= reach }
                      .min_by { |pair| [ (due_on - pair.due_on).abs, pair.due_on ] }
                      &.original_due_on
              end
              .to_set
      end

      # Just under half the cycle length, as RecurringTransaction::Matcher's
      # window_for, so generation and matching agree on a cycle's reach.
      def half_cycle(schedule)
        cycle_days = (365.25 / schedule.occurrences_per_year).floor
        [ (cycle_days - 1) / 2, 1 ].max
      end
  end
end
