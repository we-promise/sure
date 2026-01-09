class SophtronItem::Syncer
  attr_reader :sophtron_item

  def initialize(sophtron_item)
    @sophtron_item = sophtron_item
  end

  def perform_sync(sync)
    # Phase 1: Import data from Sophtron API
    sync.update!(status_text: "Importing accounts from Sophtron...") if sync.respond_to?(:status_text)
    sophtron_item.import_latest_sophtron_data

    # Phase 2: Check account setup status and collect sync statistics
    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    total_accounts = sophtron_item.sophtron_accounts.count
    linked_accounts = sophtron_item.sophtron_accounts.joins(:account).merge(Account.visible)
    unlinked_accounts = sophtron_item.sophtron_accounts.includes(:account).where(accounts: { id: nil })

    # Store sync statistics for display
    sync_stats = {
      total_accounts: total_accounts,
      linked_accounts: linked_accounts.count,
      unlinked_accounts: unlinked_accounts.count
    }

    # Set pending_account_setup if there are unlinked accounts
    if unlinked_accounts.any?
      sophtron_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      sophtron_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      Rails.logger.info "SophtronItem::Syncer - Processing #{linked_accounts.count} linked accounts"
      sophtron_item.process_accounts
      Rails.logger.info "SophtronItem::Syncer - Finished processing accounts"
      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      sophtron_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    else
      Rails.logger.info "SophtronItem::Syncer - No linked accounts to process"
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
