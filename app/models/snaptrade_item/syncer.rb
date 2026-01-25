class SnaptradeItem::Syncer
  include SyncStats::Collector

  attr_reader :snaptrade_item

  def initialize(snaptrade_item)
    @snaptrade_item = snaptrade_item
  end

  def perform_sync(sync)
    Rails.logger.info "SnaptradeItem::Syncer - Starting sync for item #{snaptrade_item.id}"

    # Verify user is registered
    unless snaptrade_item.user_registered?
      raise StandardError, "User not registered with SnapTrade"
    end

    # Phase 1: Import data from SnapTrade API
    sync.update!(status_text: "Importing accounts from SnapTrade...") if sync.respond_to?(:status_text)
    snaptrade_item.import_latest_snaptrade_data(sync: sync)

    # Phase 2: Collect setup statistics
    finalize_setup_counts(sync)

    # Phase 3: Process holdings and activities for linked accounts
    # Preload account_provider and account to avoid N+1 queries
    linked_snaptrade_accounts = snaptrade_item.linked_snaptrade_accounts.includes(account_provider: :account)
    if linked_snaptrade_accounts.any?
      sync.update!(status_text: "Processing holdings and activities...") if sync.respond_to?(:status_text)
      snaptrade_item.process_accounts

      # Phase 4: Schedule balance calculations
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      snaptrade_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      # Phase 5: Collect transaction, trades, and holdings statistics
      account_ids = linked_snaptrade_accounts.filter_map { |sa| sa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "snaptrade")
      collect_trades_stats(sync, account_ids: account_ids, source: "snaptrade")
      collect_holdings_stats(sync, holdings_count: count_holdings, label: "processed")
    end

    # Mark sync health
    collect_health_stats(sync, errors: nil)
  rescue Provider::Snaptrade::AuthenticationError => e
    snaptrade_item.update!(status: :requires_update)
    collect_health_stats(sync, errors: [ { message: e.message, category: "auth_error" } ])
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  # Public: called by Sync after finalization
  def perform_post_sync
    # no-op
  end

  private

    def count_holdings
      snaptrade_item.snaptrade_accounts.sum { |sa| Array(sa.raw_holdings_payload).size }
    end

    def finalize_setup_counts(sync)
      sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)

      total_accounts = snaptrade_item.total_accounts_count
      linked_count = snaptrade_item.linked_accounts_count
      unlinked_count = snaptrade_item.unlinked_accounts_count

      if unlinked_count > 0
        snaptrade_item.update!(pending_account_setup: true)
        sync.update!(status_text: "#{unlinked_count} accounts need setup...") if sync.respond_to?(:status_text)
      else
        snaptrade_item.update!(pending_account_setup: false)
      end

      # Collect setup stats
      collect_setup_stats(sync, provider_accounts: snaptrade_item.snaptrade_accounts)
    end
end
