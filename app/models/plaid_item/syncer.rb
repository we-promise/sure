class PlaidItem::Syncer
  include SyncStats::Collector

  attr_reader :plaid_item

  def initialize(plaid_item)
    @plaid_item = plaid_item
  end

  def perform_sync(sync)
    # Phase 1: Import data from Plaid API
    sync.update!(status_text: "Importing accounts from Plaid...") if sync.respond_to?(:status_text)
    plaid_item.import_latest_plaid_data

    # Phase 2: Collect setup statistics
    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: plaid_item.plaid_accounts)

    # Check for unlinked accounts and update pending_account_setup flag
    unlinked_count = plaid_item.plaid_accounts.count { |pa| pa.current_account.nil? }
    if unlinked_count > 0
      plaid_item.update!(pending_account_setup: true) if plaid_item.respond_to?(:pending_account_setup=)
      sync.update!(status_text: "#{unlinked_count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      plaid_item.update!(pending_account_setup: false) if plaid_item.respond_to?(:pending_account_setup=)
    end

    # Phase 3: Process the raw Plaid data and updates internal domain objects
    linked_accounts = plaid_item.plaid_accounts.select { |pa| pa.current_account.present? }
    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      mark_import_started(sync)
      plaid_item.process_accounts

      # Phase 4: Schedule balance calculations
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      plaid_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      # Phase 5: Collect transaction and holdings statistics
      account_ids = linked_accounts.filter_map { |pa| pa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "plaid")
      collect_holdings_stats(sync, holdings_count: count_holdings(linked_accounts), label: "processed")
    end

    # Mark sync health
    collect_health_stats(sync, errors: nil)
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
    # no-op
  end

  private

    def count_holdings(plaid_accounts)
      plaid_accounts.sum do |pa|
        pa.raw_holdings_payload&.dig("holdings")&.size || 0
      end
    end
end
