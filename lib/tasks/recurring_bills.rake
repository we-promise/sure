namespace :recurring do
  desc "Backfill occurrence history and reconcile it against real entries (re-runnable). MONTHS defaults to 6."
  task :backfill_history, [ :months ] => :environment do |_task, args|
    months = (args[:months] || 6).to_i
    from = months.months.ago.to_date

    Family.find_each do |family|
      next if family.recurring_transactions_disabled?

      puts "#{family.id}: backfilling #{months} months"

      family.recurring_transactions.active.find_each do |series|
        RecurringTransaction::OccurrenceGenerator.new(series).backfill!(from: from)
      end

      # Exact-tier matches only: history closes where a real entry anchors
      # it, and is never asserted where none does.
      RecurringTransaction::Matcher.new(family).run_backfill!

      # Uncovered past occurrences (before the current cycle, no payments)
      # are deleted, not marked missed -- backfill reconstructs what
      # happened, it does not fabricate debt.
      pruned = 0
      family.recurring_transactions.active.find_each do |series|
        cycle_start = series.schedule.cycle_for(Date.current)&.begin
        next if cycle_start.nil?

        pruned += series.recurring_occurrences
                        .open_status
                        .where("due_on < ?", cycle_start)
                        .where.not(id: RecurringAllocation.select(:recurring_occurrence_id))
                        .delete_all
      end

      closed = family.recurring_occurrences.paid.count
      puts "#{family.id}: #{closed} occurrences closed as paid, #{pruned} uncovered past occurrences pruned"
    end
  end
end
