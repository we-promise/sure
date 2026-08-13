class RecurringTransaction
  # Materializes Schedule output into recurring_occurrences rows. Generation
  # is an idempotent upsert keyed on (series, original_due_on): re-running it
  # can only add missing rows, never duplicate or touch existing ones -- the
  # property that keeps materialization safe (the failure mode it exists to
  # avoid is eagerly-materialized rows drifting from their schedule).
  #
  # Mutation rules: only scheduled, allocation-free, not-yet-due rows are ever
  # deleted (regenerate_future!, pausing). Anything closed or carrying a
  # payment is immutable history whatever happens to the series definition.
  class OccurrenceGenerator
    HORIZON_DAYS = 90

    attr_reader :series

    def initialize(series)
      @series = series
    end

    # Generates from the start of the current cycle (so a recently-due unpaid
    # occurrence exists, not just future ones) through the horizon -- extended
    # far enough to always include the NEXT occurrence, so slow cadences
    # (annual bills) have their upcoming obligation materialized too.
    def generate!(through: nil)
      return 0 unless series.active?

      schedule = series.schedule
      from = schedule.cycle_for(Date.current)&.begin || Date.current

      # A declared bill's anchor IS its first obligation: nothing is owed
      # before it, so the current-cycle lookback must not fabricate a
      # previous-cycle debt. Auto-detected series keep the cycle start --
      # their history predates the row.
      from = [ from, series.anchor_date ].compact.max if series.manual?

      through ||= default_horizon(schedule)

      upsert_window(from, through)
    end

    # After a schedule edit: drop the re-generatable future (scheduled, no
    # allocations, not yet due) and regenerate it under the new rules. Rows
    # with payments or closed state are kept exactly as they were.
    def regenerate_future!(through: nil)
      series.recurring_occurrences
            .open_status
            .where("due_on >= ?", Date.current)
            .where.not(id: RecurringAllocation.select(:recurring_occurrence_id))
            .delete_all

      generate!(through: through)
    end

    # Materializes a past window (catch-up/backfill). The caller decides what
    # happens to uncovered past occurrences; this only creates rows.
    def backfill!(from:, through: Date.current)
      return 0 unless series.active?

      upsert_window(from, through)
    end

    private
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
        pairs = series.schedule.occurrence_pairs_between(from, through)
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
  end
end
