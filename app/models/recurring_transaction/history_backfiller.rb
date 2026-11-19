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
    #
    # declared marks a run for a bill that was just declared: everything its
    # schedule placed before the declaration is not owed.
    def initialize(family, months: 6, series_scope: nil, as_of: Date.current, declared: false)
      @family = family
      @months = months
      @series_scope = series_scope
      @as_of = as_of
      @declared = declared
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
      # happened, it does not fabricate debt. A bill whose first due date is
      # still ahead owes nothing before it, even inside the current cycle. The
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
          anchor = series.anchor_date if series.manual? && series.anchor_date.present? && series.anchor_date > as_of
          bounds = [
            (uncovered.where("due_on < ?", cycle_start) if cycle_start),
            (uncovered.where("original_due_on < ?", anchor) if anchor),
            (uncovered.where("original_due_on < ?", as_of) if cycle_start.nil? && ended_before_declaration?(schedule))
          ].compact
          next if bounds.empty?

          pruned += bounds.reduce(:or).delete_all
        end

        pruned
      end

      # A schedule with no current cycle is otherwise skipped, so an ended plan
      # keeps its overdue final payments. Only a bill declared after its
      # schedule ended owes nothing scheduled before the declaration; the
      # scheduled date decides, so a payment the weekend moved ahead of the
      # declaration is still owed. cycle_for is also nil before a one-off
      # schedule's only date, which is still owed.
      def ended_before_declaration?(schedule)
        @declared && schedule.first_occurrence_after(as_of).nil?
      end
  end
end
