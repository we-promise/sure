# frozen_string_literal: true

class TricountItem::Syncer
  include SyncStats::Collector

  attr_reader :tricount_item

  def initialize(tricount_item)
    @tricount_item = tricount_item
  end

  def perform_sync(sync)
    Rails.logger.info "TricountItem::Syncer - Starting sync for item #{tricount_item.id}"

    # Phase 1: Import data from provider API
    sync.update!(status_text: I18n.t("tricount_items.sync.status.importing")) if sync.respond_to?(:status_text)
    refreshed_ids = tricount_item.import_latest_tricount_data(sync: sync)
    sync_errors = import_errors(sync)

    # Phase 2: Collect setup statistics
    finalize_setup_counts(sync)

    # Phase 3: Process data for linked accounts
    linked_tricount_accounts = tricount_item.linked_tricount_accounts.includes(account_provider: :account)
    if linked_tricount_accounts.any?
      sync.update!(status_text: I18n.t("tricount_items.sync.status.processing")) if sync.respond_to?(:status_text)
      mark_import_started(sync)
      # A tricount that couldn't be read keeps its account as it was.
      sync_errors.concat(processing_errors(tricount_item.process_accounts(only: Array(refreshed_ids))))

      # Phase 4: Schedule balance calculations
      sync.update!(status_text: I18n.t("tricount_items.sync.status.calculating")) if sync.respond_to?(:status_text)
      sync_errors.concat(scheduling_errors(tricount_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )))

      # Phase 5: Collect statistics
      account_ids = linked_tricount_accounts.filter_map { |pa| pa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "tricount")
    end

    # A tricount that couldn't be read, or an account that couldn't be
    # processed or recalculated, leaves the sync complete but unhealthy.
    capture_partial_failure(sync_errors) if sync_errors.any?
    collect_health_stats(sync, errors: sync_errors.presence)
  rescue Provider::Tricount::AuthenticationError => e
    tricount_item.update!(status: :requires_update)
    capture_failure(e)
    collect_health_stats(sync, errors: [ { message: e.message, category: "auth_error" } ])
    raise
  rescue => e
    capture_failure(e)
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  # Public: called by Sync after finalization
  def perform_post_sync
    # Override for post-sync cleanup if needed
  end

  private

    # The importer records a tricount it couldn't read in the sync's stats.
    def import_errors(sync)
      return [] unless sync.respond_to?(:sync_stats)

      Array(sync.sync_stats&.dig("errors")).map { |error| error.to_h.stringify_keys.merge("category" => "import_error") }
    end

    def processing_errors(results)
      Array(results).filter_map do |result|
        # The tricount account's id stays with its error, so support can find
        # the account it concerns.
        if !result[:success]
          { message: result[:error], category: "account_processing_error", tricount_account_id: result[:tricount_account_id] }
        elsif result.dig(:result, :transactions_failed).to_i.positive?
          { message: I18n.t("tricount_items.sync.errors.transactions_failed", count: result.dig(:result, :transactions_failed)), category: "transaction_import_error", tricount_account_id: result[:tricount_account_id] }
        end
      end
    end

    # schedule_account_syncs reports an account it couldn't queue rather than
    # raising; that account's history isn't recalculated.
    def scheduling_errors(results)
      Array(results).filter_map do |result|
        next if result[:success]

        { message: I18n.t("tricount_items.sync.errors.account_sync_failed", error: result[:error]), category: "account_sync_error", account_id: result[:account_id] }
      end
    end

    # A sync that failed outright, for the support debug log; Sentry gets the
    # exception from Sync.
    def capture_failure(error)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Tricount sync failed",
        source: self.class.name,
        provider_key: "tricount",
        family: tricount_item.family,
        metadata: { tricount_item_id: tricount_item.id, error_class: error.class.name, error_message: error.message }
      )
    end

    def capture_partial_failure(sync_errors)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Tricount sync finished with #{sync_errors.size} error(s)",
        source: self.class.name,
        provider_key: "tricount",
        family: tricount_item.family,
        metadata: { tricount_item_id: tricount_item.id, errors: sync_errors }
      )
    end

    def mark_import_started(sync)
      # Mark that we're now processing imported data
      sync.update!(status_text: I18n.t("tricount_items.sync.status.importing_data")) if sync.respond_to?(:status_text)
    end

    def finalize_setup_counts(sync)
      sync.update!(status_text: I18n.t("tricount_items.sync.status.checking_setup")) if sync.respond_to?(:status_text)

      unlinked_count = tricount_item.unlinked_accounts_count

      if unlinked_count > 0
        tricount_item.update!(pending_account_setup: true)
        sync.update!(status_text: I18n.t("tricount_items.sync.status.needs_setup", count: unlinked_count)) if sync.respond_to?(:status_text)
      else
        tricount_item.update!(pending_account_setup: false)
      end

      # Collect setup stats
      collect_setup_stats(sync, provider_accounts: tricount_item.tricount_accounts)
    end
end
