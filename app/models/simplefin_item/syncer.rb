class SimplefinItem::Syncer
  attr_reader :simplefin_item

  def initialize(simplefin_item)
    @simplefin_item = simplefin_item
  end

  def perform_sync(sync)
    # Balances-only fast path
    if sync.respond_to?(:sync_stats) && (sync.sync_stats || {})["balances_only"]
      sync.update!(status_text: "Refreshing balances only...") if sync.respond_to?(:status_text)
      begin
        # Use the Importer to run balances-only path
        SimplefinItem::Importer.new(simplefin_item, simplefin_provider: simplefin_item.simplefin_provider, sync: sync).import_balances_only
        # Update last_synced_at for UI freshness if the column exists
        if simplefin_item.has_attribute?(:last_synced_at)
          simplefin_item.update!(last_synced_at: Time.current)
        end
        finalize_setup_counts(sync)
        mark_completed(sync)
      rescue => e
        mark_failed(sync, e)
      end
      return
    end

    # Full sync path
    sync.update!(status_text: "Importing accounts from SimpleFin...") if sync.respond_to?(:status_text)
    simplefin_item.import_latest_simplefin_data(sync: sync)

    finalize_setup_counts(sync)

    # Process transactions/holdings only for linked accounts
    linked_accounts = simplefin_item.simplefin_accounts.joins(:account)
    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions and holdings...") if sync.respond_to?(:status_text)
      simplefin_item.process_accounts

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      simplefin_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    end

    mark_completed(sync)
  end

  # Public: called by Sync after finalization; keep no-op
  def perform_post_sync
    # no-op
  end

  private
    def finalize_setup_counts(sync)
      sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
      total_accounts = simplefin_item.simplefin_accounts.count
      linked_accounts = simplefin_item.simplefin_accounts.joins(:account)
      unlinked_accounts = simplefin_item.simplefin_accounts.includes(:account).where(accounts: { id: nil })

      if unlinked_accounts.any?
        simplefin_item.update!(pending_account_setup: true)
        sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
      else
        simplefin_item.update!(pending_account_setup: false)
      end

      if sync.respond_to?(:sync_stats)
        existing = (sync.sync_stats || {})
        setup_stats = {
          "total_accounts" => total_accounts,
          "linked_accounts" => linked_accounts.count,
          "unlinked_accounts" => unlinked_accounts.count
        }
        sync.update!(sync_stats: existing.merge(setup_stats))
      end
    end

    def mark_completed(sync)
      if sync.may_start?
        sync.start!
      end
      if sync.may_complete?
        sync.complete!
      else
        # If aasm not used, at least set status text
        sync.update!(status: :completed) if sync.status != "completed"
      end

      # After completion, compute and persist compact post-run stats for the summary panel
      begin
        post_stats = compute_post_run_stats(sync)
        if post_stats.present?
          existing = (sync.sync_stats || {})
          sync.update!(sync_stats: existing.merge(post_stats))
        end
      rescue => e
        Rails.logger.warn("SimplefinItem::Syncer#mark_completed stats error: #{e.class} - #{e.message}")
      end

      # Bump item freshness timestamp (guard column existence and skip for balances-only)
      if simplefin_item.has_attribute?(:last_synced_at) && !(sync.sync_stats || {})["balances_only"].present?
        simplefin_item.update!(last_synced_at: Time.current)
      end
    end

    # Computes transaction/holding counters between sync start and completion
    def compute_post_run_stats(sync)
      window_start = sync.created_at || 30.minutes.ago
      window_end   = Time.current

      account_ids = simplefin_item.simplefin_accounts.joins(:account).pluck("accounts.id")
      return {} if account_ids.empty?

      tx_scope = Entry.where(account_id: account_ids, source: "simplefin", entryable_type: "Transaction")
      tx_imported = tx_scope.where(created_at: window_start..window_end).count
      tx_updated  = tx_scope.where(updated_at: window_start..window_end).where.not(created_at: window_start..window_end).count
      tx_seen     = tx_imported + tx_updated

      holdings_scope = Holding.where(account_id: account_ids)
      holdings_processed = holdings_scope.where(created_at: window_start..window_end).count

      {
        "tx_imported" => tx_imported,
        "tx_updated" => tx_updated,
        "tx_seen" => tx_seen,
        "holdings_processed" => holdings_processed,
        "window_start" => window_start,
        "window_end" => window_end
      }
    end

    def mark_failed(sync, error)
      # If already completed, do not attempt to fail to avoid AASM InvalidTransition
      if sync.respond_to?(:status) && sync.status.to_s == "completed"
        Rails.logger.warn("SimplefinItem::Syncer#mark_failed called after completion: #{error.class} - #{error.message}")
        return
      end
      if sync.may_start?
        sync.start!
      end
      if sync.may_fail?
        sync.fail!
      else
        # Avoid forcing failed if transitions are not allowed
        sync.update!(status: :failed) if !sync.respond_to?(:aasm) || sync.status.to_s != "failed"
      end
      sync.update!(error: error.message) if sync.respond_to?(:error)
    end
end
