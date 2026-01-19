# Orchestrates the sync process for a Coinbase connection.
# Imports data, processes accounts, and schedules account syncs.
class CoinbaseItem::Syncer
  attr_reader :coinbase_item

  # @param coinbase_item [CoinbaseItem] Item to sync
  def initialize(coinbase_item)
    @coinbase_item = coinbase_item
  end

  # Runs the full sync workflow: import, process, and schedule.
  # @param sync [Sync] Sync record for status tracking
  def perform_sync(sync)
    # Phase 1: Check credentials are configured
    sync.update!(status_text: I18n.t("coinbase_item.syncer.checking_credentials")) if sync.respond_to?(:status_text)
    unless coinbase_item.credentials_configured?
      sync.update!(status_text: I18n.t("coinbase_item.syncer.credentials_invalid")) if sync.respond_to?(:status_text)
      coinbase_item.update!(status: :requires_update)
      return
    end

    # Phase 2: Import data from Coinbase API
    sync.update!(status_text: I18n.t("coinbase_item.syncer.importing_accounts")) if sync.respond_to?(:status_text)
    coinbase_item.import_latest_coinbase_data

    # Phase 3: Check account setup status and collect sync statistics
    sync.update!(status_text: I18n.t("coinbase_item.syncer.checking_configuration")) if sync.respond_to?(:status_text)
    total_accounts = coinbase_item.coinbase_accounts.count

    linked_accounts = coinbase_item.coinbase_accounts.joins(:account_provider).joins(:account).merge(Account.visible)
    unlinked_accounts = coinbase_item.coinbase_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    sync_stats = {
      total_accounts: total_accounts,
      linked_accounts: linked_accounts.count,
      unlinked_accounts: unlinked_accounts.count
    }

    if unlinked_accounts.any?
      coinbase_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("coinbase_item.syncer.accounts_need_setup", count: unlinked_accounts.count)) if sync.respond_to?(:status_text)
    else
      coinbase_item.update!(pending_account_setup: false)
    end

    # Phase 4: Process holdings for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: I18n.t("coinbase_item.syncer.processing_accounts")) if sync.respond_to?(:status_text)
      coinbase_item.process_accounts

      # Phase 5: Schedule balance calculations for linked accounts
      sync.update!(status_text: I18n.t("coinbase_item.syncer.calculating_balances")) if sync.respond_to?(:status_text)
      coinbase_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    end

    if sync.respond_to?(:sync_stats)
      sync.update!(sync_stats: sync_stats)
    end
  end

  # Hook called after sync completion. Currently a no-op.
  def perform_post_sync
    # no-op
  end
end
