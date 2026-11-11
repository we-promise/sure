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
        next if classification.bill_type == "bill" && classification.category_id.nil? && !classification.autopay

        series.update!(
          bill_type: classification.bill_type,
          category_id: classification.category_id,
          autopay: series.autopay || classification.autopay
        )
        reclassified += 1
        puts "  #{series.display_name}: #{classification.bill_type}#{classification.category_id ? ' +category' : ''}#{classification.autopay ? ' +autopay' : ''}"
      end

      puts "#{family.id}: #{reclassified} series classified"
    end
  end
end

namespace :recurring do
  diagnose = lambda do |bill, months|
    found = false
    Family.find_each do |family|
      next if family.recurring_transactions_disabled?

      begin
        puts RecurringTransaction::ReferenceDiagnostics.new(family, bill, months: months || 12).report
        found = true
      rescue ArgumentError
        next
      end
    end

    abort "no bill with id, name or bank reference #{bill.inspect}" unless found
  end

  desc "Read-only: explain per payment why it is or is not linked to a bill. BILL is a recurring transaction id or its bank reference; MONTHS defaults to 12."
  task :diagnose_reference, [ :bill, :months ] => :environment do |_task, args|
    abort "usage: rake recurring:diagnose_reference[<bill id or bank reference>,<months>]" if args[:bill].blank?

    diagnose.call(args[:bill], args[:months])
  end

  desc "Read-only: like diagnose_reference, for a bill without a bank reference (a recurring transfer, say): every payment on its account with its amount. BILL is a recurring transaction id, its name or its bank reference; MONTHS defaults to 12."
  task :diagnose_series, [ :bill, :months ] => :environment do |_task, args|
    abort "usage: rake recurring:diagnose_series[<bill id or name>,<months>]" if args[:bill].blank?

    diagnose.call(args[:bill], args[:months])
  end
end
