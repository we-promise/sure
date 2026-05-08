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
    import_result = sophtron_item.import_latest_sophtron_data(sync: sync)
    import_errors = import_errors_for(import_result)

    # Phase 2: Check account setup status and collect sync statistics
    sync.update!(status_text: t("sophtron_items.syncer.checking_account_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: sophtron_item.sophtron_accounts)

    # Check for unlinked accounts
    linked_accounts = sophtron_item.automatic_sync_sophtron_accounts
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
      sophtron_item.process_accounts(sophtron_accounts_scope: linked_accounts)
      Rails.logger.info "SophtronItem::Syncer - Finished processing accounts"

      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: t("sophtron_items.syncer.calculating_balances")) if sync.respond_to?(:status_text)
      sophtron_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date,
        sophtron_accounts_scope: linked_accounts
      )

      # Phase 5: Collect transaction statistics
      account_ids = linked_accounts.includes(:account_provider).filter_map { |la| la.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "sophtron")
    else
      sync.update!(status_text: t("sophtron_items.syncer.manual_sync_required")) if sophtron_item.manual_sync_required? && sync.respond_to?(:status_text)
      Rails.logger.info "SophtronItem::Syncer - No linked accounts to process"
    end

    # Mark sync health
    if import_errors.present?
      collect_health_stats(sync, errors: import_errors)
      raise StandardError.new(import_errors.map { |error| error[:message] }.join(", "))
    else
      collect_health_stats(sync, errors: nil)
    end
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ]) unless sync_errors_recorded?(sync)
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

  private

    def import_errors_for(import_result)
      return [] if import_result.blank? || import_result[:success]

      if import_result[:error].present?
        return [ { message: import_result[:error], category: "sync_error" } ]
      end

      errors = []
      if import_result[:accounts_failed].to_i.positive?
        errors << {
          message: "#{import_result[:accounts_failed]} #{'account'.pluralize(import_result[:accounts_failed])} failed to import",
          category: "account_import"
        }
      end

      if import_result[:transactions_failed].to_i.positive?
        errors << {
          message: "#{import_result[:transactions_failed]} #{'account'.pluralize(import_result[:transactions_failed])} failed to import transactions",
          category: "transaction_import"
        }
      end

      errors.presence || [ { message: "Sophtron import failed", category: "sync_error" } ]
    end

    def sync_errors_recorded?(sync)
      return false unless sync.respond_to?(:sync_stats)

      sync.sync_stats.to_h["total_errors"].to_i.positive?
    end
end
