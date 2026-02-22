# frozen_string_literal: true

namespace :data_migration do
  desc "Fix stale pending transaction metadata: self-referencing duplicates and orphaned pending flags"
  task cleanup_stale_pending: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    puts "Stale Pending Transaction Cleanup"
    puts "=================================="
    puts "Mode: #{dry_run ? 'DRY RUN (no changes)' : 'LIVE (will apply fixes)'}"
    puts "Note: Best run when no active syncs are in progress."
    puts ""

    fixed_self_refs = 0
    fixed_orphaned_refs = 0

    # ── Fix 1: Self-referencing potential_posted_match ──────────────────────
    #
    # When a pending entry was claimed as posted but its pending flag wasn't
    # cleared, the duplicate detection could match the entry against itself,
    # storing its own entry ID as the "posted match". Merging then deletes
    # the only copy of the transaction.
    #
    # Fix: Remove the potential_posted_match from entries that point to themselves.

    puts "── Fix 1: Self-referencing potential_posted_match ──"
    puts ""

    self_ref_entries = Entry.joins(
      "INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'"
    ).where(<<~SQL.squish)
      transactions.extra -> 'potential_posted_match' ->> 'entry_id' IS NOT NULL
      AND entries.id::text = transactions.extra -> 'potential_posted_match' ->> 'entry_id'
    SQL

    self_ref_entries.includes(:account).find_each do |entry|
      transaction = entry.entryable
      puts "  SELF-REF: #{entry.id} | #{entry.date} | #{entry.name} | #{entry.amount} #{entry.currency}"
      puts "    Account: #{entry.account.name}"
      puts "    Reason: #{transaction.extra.dig('potential_posted_match', 'reason')}"

      unless dry_run
        cleaned_extra = transaction.extra.deep_dup
        cleaned_extra.delete("potential_posted_match")
        transaction.update!(extra: cleaned_extra)
        puts "    → Cleared self-referencing suggestion"
      end

      fixed_self_refs += 1
      puts ""
    end

    if fixed_self_refs.zero?
      puts "  None found."
      puts ""
    end

    # ── Fix 2: Orphaned potential_posted_match (target entry deleted) ──────
    #
    # If a posted entry was deleted (manually or via sync), the pending entry's
    # potential_posted_match still references it. Merging would fail silently
    # (potential_duplicate_entry returns nil), but the stale badge remains in UI.
    #
    # Fix: Remove potential_posted_match when the target entry no longer exists.

    puts "── Fix 2: Orphaned potential_posted_match (target deleted) ──"
    puts ""

    orphan_entries = Entry.joins(
      "INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'"
    ).where(<<~SQL.squish)
      transactions.extra -> 'potential_posted_match' ->> 'entry_id' IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM entries e2
        WHERE e2.id::text = transactions.extra -> 'potential_posted_match' ->> 'entry_id'
      )
    SQL

    orphan_entries.includes(:account).find_each do |entry|
      transaction = entry.entryable
      dead_id = transaction.extra.dig("potential_posted_match", "entry_id")
      puts "  ORPHAN: #{entry.id} | #{entry.date} | #{entry.name} | #{entry.amount} #{entry.currency}"
      puts "    Account: #{entry.account.name}"
      puts "    References deleted entry: #{dead_id}"

      unless dry_run
        cleaned_extra = transaction.extra.deep_dup
        cleaned_extra.delete("potential_posted_match")
        transaction.update!(extra: cleaned_extra)
        puts "    → Cleared orphaned suggestion"
      end

      fixed_orphaned_refs += 1
      puts ""
    end

    if fixed_orphaned_refs.zero?
      puts "  None found."
      puts ""
    end

    # ── Summary ────────────────────────────────────────────────────────────

    puts "=================================="
    puts "Summary:"
    puts "  Self-referencing suggestions: #{fixed_self_refs}"
    puts "  Orphaned suggestions: #{fixed_orphaned_refs}"
    total = fixed_self_refs + fixed_orphaned_refs
    puts "  Total fixed: #{total}"
    puts ""

    if total > 0 && dry_run
      puts "To apply these fixes, run:"
      puts "  rails data_migration:cleanup_stale_pending DRY_RUN=false"
    elsif total.zero?
      puts "No stale pending data found. Nothing to clean up."
    end
  end
end
