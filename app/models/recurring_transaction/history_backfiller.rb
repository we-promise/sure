class RecurringTransaction
  # Reconstructs past occurrence history and reconciles it against real
  # entries. Re-runnable by construction: generation upserts, matching writes
  # only unambiguous exact-tier links against entries not already allocated,
  # and the prune only deletes open, unallocated rows.
  class HistoryBackfiller
    attr_reader :family, :months, :as_of

    # as_of is the day the history is reconstructed for. A deferred run
    # passes the day its caller wanted, so a backfill that waited on the
    # family lock prunes exactly what an immediate run would have.
    def initialize(family, months: 6, series_scope: nil, as_of: Date.current)
      @family = family
      @months = months
      @series_scope = series_scope
      @as_of = as_of
    end

    # Returns the number of pruned occurrences.
    def run!
      from = as_of - months.months

      series_scope.find_each do |series|
        OccurrenceGenerator.new(series).backfill!(from: from)
      end

      # Family-wide even when series_scope narrows generation: exact-tier
      # matching is idempotent and only ever closes history a real entry
      # anchors, so the wider pass is safe and keeps one Matcher entry point.
      Matcher.new(family).run_backfill!

      prune_uncovered_past!
    end

    private

      def series_scope
        @series_scope || family.recurring_transactions.active
      end

      # Uncovered past occurrences (before the current cycle, no payments)
      # are deleted, not marked missed -- backfill reconstructs what
      # happened, it does not fabricate debt. A declared bill owes nothing
      # before its first due date either, which can fall after the current
      # cycle has begun. The anchor is a scheduled date, so it bounds
      # original_due_on: weekend adjustment can move the first occurrence's
      # due_on ahead of it. A schedule that has ended by as_of has no current
      # cycle, so nothing before as_of is owed.
      def prune_uncovered_past!
        pruned = 0

        series_scope.find_each do |series|
          uncovered = series.recurring_occurrences
                            .open_status
                            .where.not(id: RecurringAllocation.select(:recurring_occurrence_id))
          cycle_start = current_cycle_start(series.schedule)
          anchor = series.anchor_date if series.manual?
          bounds = [
            (uncovered.where("due_on < ?", cycle_start) if cycle_start),
            (uncovered.where("original_due_on < ?", anchor) if anchor)
          ].compact
          next if bounds.empty?

          pruned += bounds.reduce(:or).delete_all
        end

        pruned
      end

      def current_cycle_start(schedule)
        cycle = schedule.cycle_for(as_of)
        return cycle.begin if cycle

        as_of if schedule.first_occurrence_after(as_of).nil?
      end
  end
end
