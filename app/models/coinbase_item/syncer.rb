# Orchestrates the sync process for a Coinbase connection.
# Imports data, processes accounts, and schedules account syncs.
class CoinbaseItem::Syncer
  include SyncStats::Collector

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
      error_message = I18n.t("coinbase_item.syncer.credentials_invalid")
      coinbase_item.update!(status: :requires_update)
      mark_failed(sync, error_message)
      return
    end

    # Phase 2: Import data from Coinbase API
    sync.update!(status_text: I18n.t("coinbase_item.syncer.importing_accounts")) if sync.respond_to?(:status_text)
    coinbase_item.import_latest_coinbase_data

    # Phase 3: Check account setup status and collect sync statistics
    sync.update!(status_text: I18n.t("coinbase_item.syncer.checking_configuration")) if sync.respond_to?(:status_text)

    # Use SyncStats::Collector for consistent stats (checks current_account.present? by default)
    collect_setup_stats(sync, provider_accounts: coinbase_item.coinbase_accounts.to_a)

    unlinked_accounts = coinbase_item.coinbase_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked_accounts = coinbase_item.coinbase_accounts.joins(:account_provider).joins(:account).merge(Account.visible)

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

      # Phase 6: Collect trade statistics
      account_ids = linked_accounts.map { |ca| ca.current_account&.id }.compact
      collect_transaction_stats(sync, account_ids: account_ids, source: "coinbase") if account_ids.any?
    end
  end

  # Hook called after sync completion. Currently a no-op.
  def perform_post_sync
    # no-op
  end

  private
    # Marks the sync as failed with an error message.
    # Mirrors SimplefinItem::Syncer#mark_failed for consistent failure handling.
    #
    # @param sync [Sync] The sync record to mark as failed
    # @param error_message [String] The error message to record
    def mark_failed(sync, error_message)
      if sync.respond_to?(:status) && sync.status.to_s == "completed"
        Rails.logger.warn("CoinbaseItem::Syncer#mark_failed called after completion: #{error_message}")
        return
      end

      sync.start! if sync.respond_to?(:may_start?) && sync.may_start?

      if sync.respond_to?(:may_fail?) && sync.may_fail?
        sync.fail!
      elsif sync.respond_to?(:status)
        sync.update!(status: :failed)
      end

      sync.update!(error: error_message) if sync.respond_to?(:error)
      sync.update!(status_text: error_message) if sync.respond_to?(:status_text)
    end
end
