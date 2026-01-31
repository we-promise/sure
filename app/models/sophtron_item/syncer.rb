# Orchestrates the complete sync process for a SophtronItem.
#
# The syncer coordinates multiple phases:
# 1. Import accounts and transactions from Sophtron API
# 2. Check account setup status and collect statistics
# 3. Process transactions for linked accounts
# 4. Schedule balance calculations
# 5. Collect sync statistics and health metrics
#
# This follows the same pattern as other provider syncers (SimpleFIN, Plaid)
# and integrates with the Syncable concern.
class SophtronItem::Syncer
  include SyncStats::Collector

  attr_reader :sophtron_item

  # Initializes a new syncer for a Sophtron item.
  #
  # @param sophtron_item [SophtronItem] The item to sync
  def initialize(sophtron_item)
    @sophtron_item = sophtron_item
  end

  # Performs the complete sync process.
  #
  # This method orchestrates all phases of the sync:
  # - Imports fresh data from Sophtron API
  # - Updates linked accounts and creates new account records
  # - Processes transactions for linked accounts only
  # - Schedules balance calculations
  # - Collects statistics and health metrics
  #
  # @param sync [Sync] The sync record to track progress and status
  # @return [void]
  # @raise [StandardError] if any phase of the sync fails
  def perform_sync(sync)
    # Phase 1: Import data from Sophtron API
    sync.update!(status_text: t("sophtron_items.syncer.importing_accounts")) if sync.respond_to?(:status_text)
    sophtron_item.import_latest_sophtron_data

    # Phase 2: Check account setup status and collect sync statistics
    sync.update!(status_text: t("sophtron_items.syncer.checking_account_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: sophtron_item.sophtron_accounts)

    # Check for unlinked accounts
    linked_accounts = sophtron_item.sophtron_accounts.joins(:account_provider)
    unlinked_accounts = sophtron_item.sophtron_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    # Set pending_account_setup if there are unlinked accounts
    unlinked_count = unlinked_accounts.count
    if unlinked_count.positive?
      sophtron_item.update!(pending_account_setup: true)
      sync.update!(status_text: t("sophtron_items.syncer.accounts_need_setup", count: unlinked_count)) if sync.respond_to?(:status_text)
    else
      sophtron_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: t("sophtron_items.syncer.processing_transactions")) if sync.respond_to?(:status_text)
      mark_import_started(sync)
      Rails.logger.info "SophtronItem::Syncer - Processing #{linked_accounts.count} linked accounts"
      sophtron_item.process_accounts
      Rails.logger.info "SophtronItem::Syncer - Finished processing accounts"

      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: t("sophtron_items.syncer.calculating_balances")) if sync.respond_to?(:status_text)
      sophtron_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      # Phase 5: Collect transaction statistics
      account_ids = linked_accounts.includes(:account_provider).filter_map { |la| la.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "sophtron")
    else
      Rails.logger.info "SophtronItem::Syncer - No linked accounts to process"
    end

    # Mark sync health
    collect_health_stats(sync, errors: nil)
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  # Performs post-sync cleanup or actions.
  #
  # Currently a no-op for Sophtron items. Reserved for future use.
  #
  # @return [void]
  def perform_post_sync
    # no-op
  end
end
