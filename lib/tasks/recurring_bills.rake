namespace :recurring do
  desc "Backfill occurrence history and reconcile it against real entries (re-runnable). MONTHS defaults to 6."
  task :backfill_history, [ :months ] => :environment do |_task, args|
    months = (args[:months] || 6).to_i
    from = months.months.ago.to_date

    Family.find_each do |family|
      next if family.recurring_transactions_disabled?

      puts "#{family.id}: backfilling #{months} months"

      pruned = RecurringTransaction::HistoryBackfiller.new(family, months: months).run!

      closed = family.recurring_occurrences.paid.count
      puts "#{family.id}: #{closed} occurrences closed as paid, #{pruned} uncovered past occurrences pruned"
    end
  end
end

namespace :recurring do
  desc "One-shot classification of existing auto-detected series still on defaults (kind bill, no category)"
  task classify_existing: :environment do
    Family.find_each do |family|
      next if family.recurring_transactions_disabled?

      reclassified = 0
      family.recurring_transactions
            .where(manual: false, bill_type: "bill", category_id: nil)
            .find_each do |series|
        entries = series.matching_transactions.first(6)
        next if entries.empty?

        classification = RecurringTransaction::Classifier.classify(
          name: series.display_name, entries: entries, account: series.account
        )
        next if classification.bill_type == "bill" && classification.category_id.nil?

        series.update!(
          bill_type: classification.bill_type,
          category_id: classification.category_id,
          autopay: series.autopay || classification.autopay
        )
        reclassified += 1
        puts "  #{series.display_name}: #{classification.bill_type}#{classification.category_id ? ' +category' : ''}"
      end

      puts "#{family.id}: #{reclassified} series classified"
    end
  end
end
