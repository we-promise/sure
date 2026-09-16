# frozen_string_literal: true

class QuestradeItem::Syncer
  include SyncStats::Collector

  attr_reader :questrade_item

  def initialize(questrade_item)
    @questrade_item = questrade_item
  end

  def perform_sync(sync)
    Rails.logger.info "QuestradeItem::Syncer - Starting sync for item #{questrade_item.id}"

    # Phase 1: Import data from provider API
    update_sync_status(sync, :importing)
    questrade_item.import_latest_questrade_data(sync: sync)

    # Phase 2: Collect setup statistics
    finalize_setup_counts(sync)

    # Phase 3: Process data for linked accounts
    sync_errors = nil
    linked_questrade_accounts = questrade_item.linked_questrade_accounts.includes(account_provider: :account)
    if linked_questrade_accounts.any?
      update_sync_status(sync, :processing)
      mark_import_started(sync)
      process_results = questrade_item.process_accounts

      # Phase 4: Schedule balance calculations
      update_sync_status(sync, :calculating)
      schedule_results = questrade_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      # Surface per-account processing/scheduling failures in sync health.
      sync_errors = [ *process_results, *schedule_results ].filter_map do |result|
        next if result[:success]
        { message: result[:error], category: "sync_error" }
      end.presence

      # Phase 5: Collect statistics
      account_ids = linked_questrade_accounts.filter_map { |pa| pa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "questrade")
      collect_trades_stats(sync, account_ids: account_ids, source: "questrade")
      collect_holdings_stats(sync, holdings_count: count_holdings, label: "processed")
    end

    # Mark sync health
    collect_health_stats(sync, errors: sync_errors)
  rescue Provider::Questrade::AuthenticationError => e
    questrade_item.update!(status: :requires_update)
    collect_health_stats(sync, errors: [ { message: e.message, category: "auth_error" } ])
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  # Public: called by Sync after finalization
  def perform_post_sync
    # Override for post-sync cleanup if needed
  end

  private

    def count_holdings
      questrade_item.linked_questrade_accounts.sum { |pa| Array(pa.raw_holdings_payload).size }
    end

    def update_sync_status(sync, key, **i18n_options)
      sync.update!(status_text: I18n.t("questrade_items.sync.status.#{key}", **i18n_options)) if sync.respond_to?(:status_text)
    end

    def mark_import_started(sync)
      # Mark that we're now processing imported data
      update_sync_status(sync, :importing_data)
    end

    def finalize_setup_counts(sync)
      update_sync_status(sync, :checking_setup)

      unlinked_count = questrade_item.unlinked_accounts_count

      if unlinked_count > 0
        questrade_item.update!(pending_account_setup: true)
        update_sync_status(sync, :needs_setup, count: unlinked_count)
      else
        questrade_item.update!(pending_account_setup: false)
      end

      # Collect setup stats
      collect_setup_stats(sync, provider_accounts: questrade_item.questrade_accounts)
    end
end
