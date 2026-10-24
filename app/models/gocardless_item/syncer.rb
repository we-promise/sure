# frozen_string_literal: true

class GocardlessItem::Syncer
  include SyncStats::Collector

  attr_reader :gocardless_item

  def initialize(gocardless_item)
    @gocardless_item = gocardless_item
  end

  def perform_sync(sync)
    Rails.logger.info "GocardlessItem::Syncer - Starting sync for item #{gocardless_item.id}"

    # Phase 1: Import data from provider API
    sync.update!(status_text: I18n.t("gocardless_items.sync.status.importing")) if sync.respond_to?(:status_text)
    gocardless_item.import_latest_gocardless_data(sync: sync)

    # Phase 2: Collect setup statistics
    finalize_setup_counts(sync)

    # Phase 3: Process data for linked accounts
    linked_gocardless_accounts = gocardless_item.linked_gocardless_accounts.includes(account_provider: :account)
    if linked_gocardless_accounts.any?
      sync.update!(status_text: I18n.t("gocardless_items.sync.status.processing")) if sync.respond_to?(:status_text)
      mark_import_started(sync)
      gocardless_item.process_accounts

      # Phase 4: Schedule balance calculations
      sync.update!(status_text: I18n.t("gocardless_items.sync.status.calculating")) if sync.respond_to?(:status_text)
      gocardless_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      # Phase 5: Collect statistics
      account_ids = linked_gocardless_accounts.filter_map { |pa| pa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "gocardless")
    end

    # Mark sync health
    collect_health_stats(sync, errors: nil)
  rescue Provider::Gocardless::AuthenticationError => e
    gocardless_item.update!(status: :requires_update)
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

    def mark_import_started(sync)
      # Mark that we're now processing imported data
      sync.update!(status_text: I18n.t("gocardless_items.sync.status.importing_data")) if sync.respond_to?(:status_text)
    end

    def finalize_setup_counts(sync)
      sync.update!(status_text: I18n.t("gocardless_items.sync.status.checking_setup")) if sync.respond_to?(:status_text)

      unlinked_count = gocardless_item.unlinked_accounts_count

      if unlinked_count > 0
        gocardless_item.update!(pending_account_setup: true)
        sync.update!(status_text: I18n.t("gocardless_items.sync.status.needs_setup", count: unlinked_count)) if sync.respond_to?(:status_text)
      else
        gocardless_item.update!(pending_account_setup: false)
      end

      # Collect setup stats
      collect_setup_stats(sync, provider_accounts: gocardless_item.gocardless_accounts)
    end
end
