class RecurringTransaction
  # Reconstructs past occurrence history and reconciles it against real
  # entries. Re-runnable by construction: generation upserts, matching writes
  # only unambiguous exact-tier links against entries not already allocated,
  # and the prune only deletes open, unallocated rows.
  class HistoryBackfiller
    attr_reader :family, :months

    def initialize(family, months: 6, series_scope: nil)
      @family = family
      @months = months
      @series_scope = series_scope
    end

    # Returns the number of pruned occurrences.
    def run!
      from = months.months.ago.to_date

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
      # happened, it does not fabricate debt.
      def prune_uncovered_past!
        pruned = 0

        series_scope.find_each do |series|
          cycle_start = series.schedule.cycle_for(Date.current)&.begin
          next if cycle_start.nil?

          pruned += series.recurring_occurrences
                          .open_status
                          .where("due_on < ?", cycle_start)
                          .where.not(id: RecurringAllocation.select(:recurring_occurrence_id))
                          .delete_all
        end

        pruned
      end
  end
end
