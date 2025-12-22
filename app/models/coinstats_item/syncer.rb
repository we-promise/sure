class CoinstatsItem::Syncer
  attr_reader :coinstats_item

  def initialize(coinstats_item)
    @coinstats_item = coinstats_item
  end

  def perform_sync(sync)
    # Phase 1: Import data from CoinStats API
    sync.update!(status_text: "Importing wallets from CoinStats...") if sync.respond_to?(:status_text)
    coinstats_item.import_latest_coinstats_data

    # Phase 2: Check account setup status and collect sync statistics
    sync.update!(status_text: "Checking wallet configuration...") if sync.respond_to?(:status_text)
    total_accounts = coinstats_item.coinstats_accounts.count

    linked_accounts = coinstats_item.coinstats_accounts.joins(:account_provider).joins(:account).merge(Account.visible)
    unlinked_accounts = coinstats_item.coinstats_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    sync_stats = {
      total_accounts: total_accounts,
      linked_accounts: linked_accounts.count,
      unlinked_accounts: unlinked_accounts.count
    }

    if unlinked_accounts.any?
      coinstats_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} wallets need setup...") if sync.respond_to?(:status_text)
    else
      coinstats_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process holdings for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: "Processing holdings...") if sync.respond_to?(:status_text)
      coinstats_item.process_accounts

      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      coinstats_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    end

    if sync.respond_to?(:sync_stats)
      sync.update!(sync_stats: sync_stats)
    end
  end

  def perform_post_sync
    # no-op
  end
end
