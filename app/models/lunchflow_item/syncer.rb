class LunchflowItem::Syncer
  attr_reader :lunchflow_item

  def initialize(lunchflow_item)
    @lunchflow_item = lunchflow_item
  end

  def perform_sync(sync)
    # Phase 1: Import data from Lunchflow API
    sync.update!(status_text: "Importing accounts from Lunchflow...") if sync.respond_to?(:status_text)
    lunchflow_item.import_latest_lunchflow_data

    # Phase 2: Check account setup status and collect sync statistics
    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    total_accounts = lunchflow_item.lunchflow_accounts.count
    linked_accounts = lunchflow_item.lunchflow_accounts.joins(:account).merge(Account.visible)
    unlinked_accounts = lunchflow_item.lunchflow_accounts.includes(:account).where(accounts: { id: nil })

    # Store sync statistics for display
    sync_stats = {
      total_accounts: total_accounts,
      linked_accounts: linked_accounts.count,
      unlinked_accounts: unlinked_accounts.count
    }

    # Set pending_account_setup if there are unlinked accounts
    if unlinked_accounts.any?
      lunchflow_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      lunchflow_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      Rails.logger.info "LunchflowItem::Syncer - Processing #{linked_accounts.count} linked accounts"
      lunchflow_item.process_accounts
      Rails.logger.info "LunchflowItem::Syncer - Finished processing accounts"

      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      lunchflow_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    else
      Rails.logger.info "LunchflowItem::Syncer - No linked accounts to process"
    end

    # Store sync statistics in the sync record for status display
    if sync.respond_to?(:sync_stats)
      sync.update!(sync_stats: sync_stats)
    end
  end

  def perform_post_sync
    # no-op
  end
end
