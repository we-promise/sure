class TruelayerItem::Syncer
  include SyncStats::Collector

  attr_reader :truelayer_item

  def initialize(truelayer_item)
    @truelayer_item = truelayer_item
  end

  def perform_sync(sync)
    sync.update!(status_text: "Importing accounts from TrueLayer...") if sync.respond_to?(:status_text)
    import_result = truelayer_item.import_latest_truelayer_data

    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: truelayer_item.truelayer_accounts)

    linked_accounts = truelayer_item.truelayer_accounts.joins(:account_provider)
    unlinked_count = truelayer_item.unlinked_accounts_count
    truelayer_item.update!(pending_account_setup: unlinked_count.positive?)
    sync.update!(status_text: "#{unlinked_count} accounts need setup...") if unlinked_count.positive? && sync.respond_to?(:status_text)

    processing_results = []
    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      mark_import_started(sync)
      processing_results = truelayer_item.process_accounts

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      truelayer_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      account_ids = linked_accounts.includes(:account_provider).filter_map { |ta| ta.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "truelayer")
    end

    errors = import_failures_as_errors(import_result) + processing_failures_as_errors(processing_results)
    collect_health_stats(sync, errors: errors.presence)
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
    # no-op
  end

  private

    def import_failures_as_errors(import_result)
      return [] unless import_result.is_a?(Hash)
      return [] if import_result[:success]

      %i[accounts_failed transactions_failed balances_failed].filter_map do |key|
        count = import_result[key].to_i
        next unless count.positive?

        { message: I18n.t("provider_warnings.truelayer_#{key}", count: count), category: "truelayer_import" }
      end
    end

    # Accounts whose processing raised, and transactions that could not be
    # imported, would otherwise leave the sync looking healthy over stale data.
    def processing_failures_as_errors(results)
      results = Array(results)
      failed_accounts = results.count { |result| !result[:success] }
      failed_entries = results.sum { |result| result.dig(:result, :failed).to_i }

      errors = []
      errors << { message: I18n.t("provider_warnings.truelayer_processing_failed", count: failed_accounts), category: "truelayer_import" } if failed_accounts.positive?
      errors << { message: I18n.t("provider_warnings.truelayer_entries_failed", count: failed_entries), category: "truelayer_import" } if failed_entries.positive?
      errors
    end
end
