namespace :lunchflow do
  desc "Cleanup stuck pending Lunchflow transactions that have posted duplicates"
  task cleanup_stuck_pending: :environment do
    puts "Finding stuck pending Lunchflow transactions..."

    stuck_pending = Transaction
      .pending
      .where("transactions.extra -> 'lunchflow' ->> 'pending' = 'true'")
      .includes(:entry)
      .where(entries: { source: "lunchflow" })

    puts "Found #{stuck_pending.count} pending Lunchflow transactions"
    puts ""

    deleted_count = 0
    kept_count = 0

    stuck_pending.each do |transaction|
      pending_entry = transaction.entry

      # Search for a posted version with same merchant name, amount, and date window
      # Note: Lunchflow never provides real IDs for pending transactions, so external_id pattern
      # matching is sufficient. We still exclude self (pending_entry.id) for extra safety.
      posted_match = Entry
        .where(source: "lunchflow")
        .where(account_id: pending_entry.account_id)
        .where(name: pending_entry.name)
        .where(amount: pending_entry.amount)
        .where(currency: pending_entry.currency)
        .where("date BETWEEN ? AND ?", pending_entry.date, pending_entry.date + 8)
        .where("external_id NOT LIKE 'lunchflow_pending_%'")
        .where("external_id IS NOT NULL")
        .where.not(id: pending_entry.id)
        .order(date: :asc) # Prefer closest date match
        .first

      if posted_match
        puts "DELETING duplicate pending entry:"
        puts "  Pending: #{pending_entry.date} | #{pending_entry.name} | #{pending_entry.amount} | #{pending_entry.external_id}"
        puts "  Posted:  #{posted_match.date} | #{posted_match.name} | #{posted_match.amount} | #{posted_match.external_id}"

        # Delete the pending entry (this will also delete the transaction via cascade)
        pending_entry.destroy!
        deleted_count += 1
        puts "  ✓ Deleted"
        puts ""
      else
        puts "KEEPING (no posted duplicate found):"
        puts "  #{pending_entry.date} | #{pending_entry.name} | #{pending_entry.amount} | #{pending_entry.external_id}"
        puts "  This may be legitimately still pending, or posted with different details"
        puts ""
        kept_count += 1
      end
    end

    puts "="*80
    puts "Cleanup complete!"
    puts "  Deleted: #{deleted_count} duplicate pending entries"
    puts "  Kept: #{kept_count} entries (no posted version found)"
  end
end
