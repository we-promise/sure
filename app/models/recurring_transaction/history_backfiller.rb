class RecurringTransaction
  # Reconstructs past occurrence history and reconciles it against real
  # entries. Re-runnable by construction: generation upserts, matching writes
  # only unambiguous exact-tier links against entries not already allocated,
  # and the prune only deletes open, unallocated rows.
  #
  # `from:` overrides the default lookback. `keep_history:` is for a bill with
  # a user-declared started_on: generated past cycles are kept as history
  # instead of being pruned as fabricated debt.
  class HistoryBackfiller
    HISTORY_CYCLES = 12

    attr_reader :family, :from, :keep_history

    def initialize(family, months: 6, from: nil, series_scope: nil, keep_history: false)
      @family = family
      @from = from || months.months.ago.to_date
      @series_scope = series_scope
      @keep_history = keep_history
    end

    # Returns the number of pruned occurrences.
    def run!
      series_scope.find_each do |series|
        OccurrenceGenerator.new(series).backfill!(
          from: from,
          historical: keep_history,
          history_cycles: keep_history ? HISTORY_CYCLES : nil
        )
      end

      # Family-wide even when series_scope narrows generation: exact-tier
      # matching is idempotent and only ever closes history a real entry
      # anchors, so the wider pass is safe and keeps one Matcher entry point.
      # A declared history keeps its historical rows available to that pass.
      Matcher.new(family).run_backfill!

      # Existing non-historical past rows are real debt, not backfilled
      # history; they are deliberately not promoted here.
      keep_history ? 0 : prune_uncovered_past!
    end

    private

      def series_scope
        @series_scope || family.recurring_transactions.active
      end

      # Uncovered past occurrences (before the current cycle, no payments)
      # are deleted, not marked missed -- backfill reconstructs what
      # happened, it does not fabricate debt. Declared history is kept.
      def prune_uncovered_past!
        pruned = 0

        series_scope.find_each do |series|
          cycle_start = series.schedule.cycle_for(Date.current)&.begin
          next if cycle_start.nil?

          pruned += series.recurring_occurrences
                          .where(historical: false)
                          .open_status
                          .where("due_on < ?", cycle_start)
                          .where.not(id: RecurringAllocation.select(:recurring_occurrence_id))
                          .delete_all
        end

        pruned
      end
  end
end
