class SimplefinItem::Syncer
  attr_reader :simplefin_item

  def initialize(simplefin_item)
    @simplefin_item = simplefin_item
  end

  def perform_sync(sync)
    # Phase 1: Import data from SimpleFin API
    sync.update!(status_text: "Importing accounts from SimpleFin...") if sync.respond_to?(:status_text)
    importer = SimplefinItem::Importer.new(simplefin_item, simplefin_provider: simplefin_item.simplefin_provider)
    importer.import

    # Phase 2: Check account setup status and collect sync statistics
    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    total_accounts = simplefin_item.simplefin_accounts.count
    linked_accounts = simplefin_item.simplefin_accounts.joins(:account)
    unlinked_accounts = simplefin_item.simplefin_accounts.includes(:account).where(accounts: { id: nil })

    # Store sync statistics for display
    sync_stats = {
      total_accounts: total_accounts,
      linked_accounts: linked_accounts.count,
      unlinked_accounts: unlinked_accounts.count
    }

    # Set pending_account_setup if there are unlinked accounts
    if unlinked_accounts.any?
      simplefin_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      simplefin_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions and holdings for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions and holdings...") if sync.respond_to?(:status_text)
      simplefin_item.process_accounts

      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      simplefin_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    end

    # Store sync statistics in the sync record for status display
    if sync.respond_to?(:sync_stats)
      # If importer was used above, include skipped account count when available
      if defined?(importer) && importer.respond_to?(:skipped_accounts)
        sync_stats[:skipped_accounts] = importer.skipped_accounts.count
      end
      sync.update!(sync_stats: sync_stats)
    end
  end

  def perform_post_sync
    # no-op
  end
end
