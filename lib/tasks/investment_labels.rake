# frozen_string_literal: true

# Backfill investment activity labels for existing transactions
#
# Usage examples:
#   # Preview (dry run) - show what labels would be set
#   bin/rails 'sure:investments:backfill_labels[dry_run=true]'
#
#   # Execute the backfill for all investment/crypto accounts
#   bin/rails 'sure:investments:backfill_labels[dry_run=false]'
#
#   # Backfill for a specific account
#   bin/rails 'sure:investments:backfill_labels[account_id=8b46387c-5aa4-4a92-963a-4392c10999c9,dry_run=false]'
#
#   # Force re-label already-labeled transactions
#   bin/rails 'sure:investments:backfill_labels[dry_run=false,force=true]'

namespace :sure do
  namespace :investments do
    desc "Backfill activity labels for existing investment transactions. Args: account_id (optional), dry_run=true, force=false"
    task :backfill_labels, [ :account_id, :dry_run, :force ] => :environment do |_, args|
      # Support named args (key=value) - parse all positional args for key=value pairs
      kv = {}
      [ args[:account_id], args[:dry_run], args[:force] ].each do |raw|
        next unless raw.is_a?(String) && raw.include?("=")
        k, v = raw.split("=", 2)
        kv[k.to_s] = v
      end

      # Only use positional args if they don't contain "=" (otherwise they're named args in wrong position)
      positional_account_id = args[:account_id] unless args[:account_id].to_s.include?("=")
      positional_dry_run = args[:dry_run] unless args[:dry_run].to_s.include?("=")
      positional_force = args[:force] unless args[:force].to_s.include?("=")

      account_id = (kv["account_id"] || positional_account_id).presence
      dry_raw = (kv["dry_run"] || positional_dry_run).to_s.downcase
      force_raw = (kv["force"] || positional_force).to_s.downcase
      force = %w[true yes 1].include?(force_raw)

      # Default to dry_run=true unless explicitly disabled
      dry_run = if dry_raw.blank?
        true
      elsif %w[1 true yes y].include?(dry_raw)
        true
      elsif %w[0 false no n].include?(dry_raw)
        false
      else
        puts({ ok: false, error: "invalid_argument", message: "dry_run must be one of: true/yes/1 or false/no/0" }.to_json)
        exit 1
      end

      # Build account scope
      accounts = if account_id.present?
        Account.where(id: account_id)
      else
        Account.where(accountable_type: %w[Investment Crypto])
      end

      if accounts.none?
        puts({ ok: false, error: "no_accounts", message: "No investment/crypto accounts found" }.to_json)
        exit 1
      end

      total_processed = 0
      total_labeled = 0
      total_skipped = 0
      total_errors = 0

      accounts.find_each do |account|
        # Skip non-investment/crypto accounts if processing all
        next unless account.investment? || account.crypto?

        acct_processed = 0
        acct_labeled = 0
        acct_skipped = 0
        acct_errors = 0

        # Find transactions (optionally include already-labeled if force=true)
        entries = account.entries
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")

        unless force
          entries = entries.where("transactions.investment_activity_label IS NULL OR transactions.investment_activity_label = ''")
        end

        entries.find_each do |entry|
          acct_processed += 1
          total_processed += 1

          begin
            transaction = entry.transaction
            current_label = transaction.investment_activity_label
            label = InvestmentActivityDetector.infer_label_from_description(entry.name, entry.amount, account)

            # Skip if no label can be inferred
            if label.blank?
              acct_skipped += 1
              total_skipped += 1
              next
            end

            # Skip if label unchanged (when force=true)
            if current_label == label
              acct_skipped += 1
              total_skipped += 1
              next
            end

            if dry_run
              if current_label.present?
                puts "  [DRY RUN] Would relabel '#{entry.name}' (#{entry.amount}) from '#{current_label}' to '#{label}'"
              else
                puts "  [DRY RUN] Would label '#{entry.name}' (#{entry.amount}) as '#{label}'"
              end
            else
              transaction.update!(investment_activity_label: label)
              if current_label.present?
                puts "  Relabeled '#{entry.name}' (#{entry.amount}) from '#{current_label}' to '#{label}'"
              else
                puts "  Labeled '#{entry.name}' (#{entry.amount}) as '#{label}'"
              end
            end
            acct_labeled += 1
            total_labeled += 1
          rescue => e
            acct_errors += 1
            total_errors += 1
            puts({ error: e.class.name, message: e.message, entry_id: entry.id }.to_json)
          end
        end

        puts({ account_id: account.id, account_name: account.name, accountable_type: account.accountable_type, processed: acct_processed, labeled: acct_labeled, skipped: acct_skipped, errors: acct_errors, dry_run: dry_run, force: force }.to_json)
      end

      puts({ ok: true, total_processed: total_processed, total_labeled: total_labeled, total_skipped: total_skipped, total_errors: total_errors, dry_run: dry_run }.to_json)
    end

    desc "Clear all investment activity labels (for testing). Args: account_id (required), dry_run=true"
    task :clear_labels, [ :account_id, :dry_run ] => :environment do |_, args|
      kv = {}
      [ args[:account_id], args[:dry_run] ].each do |raw|
        next unless raw.is_a?(String) && raw.include?("=")
        k, v = raw.split("=", 2)
        kv[k.to_s] = v
      end

      # Only use positional args if they don't contain "="
      positional_account_id = args[:account_id] unless args[:account_id].to_s.include?("=")
      positional_dry_run = args[:dry_run] unless args[:dry_run].to_s.include?("=")

      account_id = (kv["account_id"] || positional_account_id).presence
      dry_raw = (kv["dry_run"] || positional_dry_run).to_s.downcase

      unless account_id.present?
        puts({ ok: false, error: "usage", message: "Provide account_id" }.to_json)
        exit 1
      end

      dry_run = if dry_raw.blank?
        true
      elsif %w[1 true yes y].include?(dry_raw)
        true
      else
        false
      end

      account = Account.find(account_id)

      count = account.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where("transactions.investment_activity_label IS NOT NULL AND transactions.investment_activity_label != ''")
        .count

      if dry_run
        puts({ ok: true, message: "Would clear #{count} labels", dry_run: true }.to_json)
      else
        Transaction.joins(:entry)
          .where(entries: { account_id: account_id })
          .where("investment_activity_label IS NOT NULL AND investment_activity_label != ''")
          .update_all(investment_activity_label: nil)
        puts({ ok: true, message: "Cleared #{count} labels", dry_run: false }.to_json)
      end
    end
  end
end
