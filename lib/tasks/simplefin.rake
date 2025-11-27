# frozen_string_literal: true

namespace :sure do
  namespace :simplefin do
    desc "Print debug info for a SimpleFin item: latest sync, snapshot accounts, simplefin_accounts, and unlinked list"
    task :debug, [ :item_id ] => :environment do |_, args|
      unless args[:item_id].present?
        puts({ error: "usage", example: "bin/rails sure:simplefin:debug[ITEM_ID]" }.to_json)
        exit 1
      end

      item = SimplefinItem.find(args[:item_id])
      latest_sync = item.syncs.order(created_at: :desc).first
      # Our model stores the latest snapshot directly on the item (`raw_payload`).
      snapshot_accounts = item.raw_payload&.dig(:accounts)&.size
      unlinked = item.simplefin_accounts.left_joins(:account).where(accounts: { id: nil })

      out = {
        item_id: item.id,
        name: item.name,
        last_synced_at: item.last_synced_at,
        latest_sync: latest_sync&.attributes&.slice("id", "status", "error", "status_text", "created_at", "completed_at"),
        snapshot_accounts: snapshot_accounts,
        simplefin_accounts_count: item.simplefin_accounts.count,
        unlinked_count: unlinked.count,
        unlinked: unlinked.limit(20).map { |sfa| { id: sfa.id, upstream_id: sfa.account_id, name: sfa.name } }
      }

      puts out.to_json
    rescue => e
      puts({ error: e.class.name, message: e.message, backtrace: e.backtrace&.take(3) }.to_json)
      exit 1
    end
    desc "Encrypt existing SimpleFin access_url values (idempotent). Args: batch_size, limit, dry_run"
    task :encrypt_access_urls, [ :batch_size, :limit, :dry_run ] => :environment do |_, args|
      Rake::Task["sure:encrypt_access_urls"].invoke(args[:batch_size], args[:limit], args[:dry_run])
    end
  end

  desc "Encrypt existing SimpleFin access_url values (idempotent). Args: batch_size, limit, dry_run"
  task :encrypt_access_urls, [ :batch_size, :limit, :dry_run ] => :environment do |_, args|
    # Parse args or fall back to ENV overrides for convenience
    raw_batch = args[:batch_size].presence || ENV["BATCH_SIZE"].presence || ENV["SURE_BATCH_SIZE"].presence
    raw_limit = args[:limit].presence || ENV["LIMIT"].presence || ENV["SURE_LIMIT"].presence
    raw_dry   = args[:dry_run].presence || ENV["DRY_RUN"].presence || ENV["SURE_DRY_RUN"].presence

    batch_size = raw_batch.to_i
    batch_size = 100 if batch_size <= 0

    limit = raw_limit.to_i
    limit = nil if limit <= 0

    # Default to non-destructive (dry run) unless explicitly disabled
    dry_run = case raw_dry.to_s.strip.downcase
    when "0", "false", "no", "n" then false
    when "1", "true", "yes", "y" then true
    else
      true
    end

    # Guard: ensure encryption is configured (centralized on the model)
    encryption_ready = SimplefinItem.encryption_ready?

    unless encryption_ready
      puts({
        ok: false,
        error: "encryption_not_configured",
        message: "Rails.application.credentials.active_record_encryption is missing; cannot encrypt access_url"
      }.to_json)
      exit 1
    end

    total_seen = 0
    total_updated = 0
    failed = []

    scope = SimplefinItem.order(:id)

    begin
      scope.in_batches(of: batch_size) do |batch|
        batch.each do |item|
          break if limit && total_seen >= limit
          total_seen += 1

          next if dry_run

          begin
            # Reassign to trigger encryption on write
            item.update!(access_url: item.access_url)
            total_updated += 1
          rescue ActiveRecord::RecordInvalid => e
            failed << { id: item.id, error: e.class.name, message: e.message }
          rescue ActiveRecord::StatementInvalid => e
            failed << { id: item.id, error: e.class.name, message: e.message }
          rescue => e
            failed << { id: item.id, error: e.class.name, message: e.message }
          end
        end

        break if limit && total_seen >= limit
      end

      puts({
        ok: true,
        dry_run: dry_run,
        batch_size: batch_size,
        limit: limit,
        processed: total_seen,
        updated: total_updated,
        failed_count: failed.size,
        failed_samples: failed.take(5)
      }.to_json)
    rescue => e
      puts({ ok: false, error: e.class.name, message: e.message, backtrace: e.backtrace&.take(3) }.to_json)
      exit 1
    end
  end
end
