class RecurringTransaction
  # Reconstructs past occurrence history and reconciles it against real
  # entries. Re-runnable by construction: generation upserts, matching writes
  # only unambiguous exact-tier links against entries not already allocated,
  # and the prune only deletes open, unallocated rows.
  class HistoryBackfiller
    attr_reader :family, :months, :as_of

    # as_of bounds the prune and the start of the backfill window. A deferred
    # run passes the day its caller wanted, so a backfill that waited on the
    # family lock deletes no more than an immediate run would have. Generation
    # and matching still run for today: rows due after as_of were owed.
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
      # happened, it does not fabricate debt. A declared bill whose first due
      # date is still ahead owes nothing before it, even inside the current
      # cycle. The
      # anchor is a scheduled date, so it bounds original_due_on: weekend
      # adjustment can move the first occurrence's due_on ahead of it. An
      # anchor already passed is bounded by the cycle, and may not be a first
      # due date at all (presets and the edit form fill it from the last
      # payment).
      def prune_uncovered_past!
        pruned = 0

        series_scope.find_each do |series|
          uncovered = series.recurring_occurrences
                            .open_status
                            .where.not(id: RecurringAllocation.select(:recurring_occurrence_id))
          schedule = series.schedule
          cycle_start = schedule.cycle_for(as_of)&.begin
          declared_on = series.declared_on
          anchor = series.anchor_date if declared_on && series.manual? && series.anchor_date.present? && series.anchor_date > as_of
          bounds = [
            (uncovered.where("due_on < ?", cycle_start) if cycle_start),
            (uncovered.where("original_due_on < ?", anchor) if anchor),
            (uncovered.where("original_due_on < ?", declared_on) if cycle_start.nil? && ended_before?(schedule, declared_on))
          ].compact
          next if bounds.empty?

          pruned += bounds.reduce(:or).delete_all
        end

        pruned
      end

      # A schedule with no current cycle is otherwise skipped, so an ended plan
      # keeps its overdue final payments. Only a bill declared after its
      # schedule ended owes nothing scheduled before the declaration, in this
      # run and every later one, so a family backfill cannot bring those rows
      # back. The scheduled date decides, so a payment the weekend moved ahead
      # of the declaration is still owed. cycle_for is also nil before a
      # one-off schedule's only date, which is still owed. A series with no
      # declared_on (detected, or created before it was recorded) is skipped.
      def ended_before?(schedule, declared_on)
        declared_on.present? && schedule.first_occurrence_after(declared_on).nil?
      end
  end
end
