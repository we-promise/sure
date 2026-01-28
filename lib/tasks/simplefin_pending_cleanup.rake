# frozen_string_literal: true

namespace :simplefin do
  desc "Find and optionally remove duplicate pending transactions that have matching posted versions"
  task pending_cleanup: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    date_window = (ENV["DATE_WINDOW"] || 8).to_i

    puts "SimpleFIN Pending Transaction Cleanup"
    puts "======================================"
    puts "Mode: #{dry_run ? 'DRY RUN (no changes)' : 'LIVE (will delete duplicates)'}"
    puts "Date window: #{date_window} days"
    puts ""

    # Find all pending SimpleFIN transactions
    pending_entries = Entry.joins(
      "INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'"
    ).where(source: "simplefin")
     .where("transactions.extra -> 'simplefin' ->> 'pending' = ?", "true")
     .includes(:account)

    puts "Found #{pending_entries.count} pending SimpleFIN transactions"
    puts ""

    duplicates_found = 0
    duplicates_to_delete = []

    pending_entries.find_each do |pending_entry|
      # Look for a matching posted transaction
      posted_match = Entry.joins(
        "INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'"
      ).where(account_id: pending_entry.account_id)
       .where(source: "simplefin")
       .where(amount: pending_entry.amount)
       .where(currency: pending_entry.currency)
       .where(date: pending_entry.date..(pending_entry.date + date_window.days)) # Posted must be ON or AFTER pending
       .where.not(id: pending_entry.id)
       .where("transactions.extra -> 'simplefin' ->> 'pending' != ? OR transactions.extra -> 'simplefin' ->> 'pending' IS NULL", "true")
       .first

      if posted_match
        duplicates_found += 1
        duplicates_to_delete << pending_entry

        puts "DUPLICATE FOUND:"
        puts "  Pending: ID=#{pending_entry.id} | #{pending_entry.date} | #{pending_entry.name} | #{pending_entry.amount} #{pending_entry.currency}"
        puts "  Posted:  ID=#{posted_match.id} | #{posted_match.date} | #{posted_match.name} | #{posted_match.amount} #{posted_match.currency}"
        puts "  Account: #{pending_entry.account.name}"
        puts ""
      end
    end

    puts "======================================"
    puts "Summary: #{duplicates_found} duplicate pending transactions found"
    puts ""

    if duplicates_found > 0
      if dry_run
        puts "To delete these duplicates, run:"
        puts "  rails simplefin:pending_cleanup DRY_RUN=false"
        puts ""
        puts "To adjust the date matching window (default 8 days):"
        puts "  rails simplefin:pending_cleanup DATE_WINDOW=14"
      else
        print "Deleting #{duplicates_to_delete.count} duplicate pending entries... "
        Entry.where(id: duplicates_to_delete.map(&:id)).destroy_all
        puts "Done!"
      end
    else
      puts "No duplicates found. Nothing to clean up."
    end
  end

  desc "Un-exclude pending transactions that were wrongly matched (fixes direction bug)"
  task pending_restore: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    date_window = (ENV["DATE_WINDOW"] || 8).to_i

    puts "Restore Wrongly Excluded Pending Transactions"
    puts "=============================================="
    puts "Mode: #{dry_run ? 'DRY RUN (no changes)' : 'LIVE (will restore)'}"
    puts "Date window: #{date_window} days (forward only)"
    puts ""

    # Find all EXCLUDED pending transactions (these may have been wrongly excluded)
    excluded_pending = Entry.joins(
      "INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'"
    ).where(excluded: true)
     .where(<<~SQL.squish)
       (transactions.extra -> 'simplefin' ->> 'pending')::boolean = true
       OR (transactions.extra -> 'plaid' ->> 'pending')::boolean = true
     SQL

    puts "Found #{excluded_pending.count} excluded pending transactions to evaluate"
    puts ""

    to_restore = []

    excluded_pending.includes(:account).find_each do |pending_entry|
      # Check if there's a VALID posted match using CORRECT logic (forward-only dates)
      # Posted date must be ON or AFTER pending date
      valid_match = pending_entry.account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where.not(id: pending_entry.id)
        .where(currency: pending_entry.currency)
        .where(amount: pending_entry.amount)
        .where(date: pending_entry.date..(pending_entry.date + date_window.days))
        .where(<<~SQL.squish)
          (transactions.extra -> 'simplefin' ->> 'pending')::boolean IS NOT TRUE
          AND (transactions.extra -> 'plaid' ->> 'pending')::boolean IS NOT TRUE
        SQL
        .exists?

      unless valid_match
        to_restore << pending_entry
        puts "SHOULD RESTORE (no valid match):"
        puts "  ID=#{pending_entry.id} | #{pending_entry.date} | #{pending_entry.name} | #{pending_entry.amount} #{pending_entry.currency}"
        puts "  Account: #{pending_entry.account.name}"
        puts ""
      end
    end

    puts "=============================================="
    puts "Summary: #{to_restore.count} transactions should be restored"
    puts ""

    if to_restore.any?
      if dry_run
        puts "To restore these transactions, run:"
        puts "  rails simplefin:pending_restore DRY_RUN=false"
      else
        Entry.where(id: to_restore.map(&:id)).update_all(excluded: false)
        puts "Restored #{to_restore.count} transactions!"
      end
    else
      puts "No wrongly excluded transactions found."
    end
  end

  desc "List all pending SimpleFIN transactions (for review)"
  task pending_list: :environment do
    pending_entries = Entry.joins(
      "INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'"
    ).where(source: "simplefin")
     .where("transactions.extra -> 'simplefin' ->> 'pending' = ?", "true")
     .includes(:account)
     .order(date: :desc)

    puts "All Pending SimpleFIN Transactions"
    puts "==================================="
    puts "Total: #{pending_entries.count}"
    puts ""

    pending_entries.find_each do |entry|
      puts "ID=#{entry.id} | #{entry.date} | #{entry.name.truncate(40)} | #{entry.amount} #{entry.currency} | Account: #{entry.account.name}"
    end
  end
end
