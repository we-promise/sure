# frozen_string_literal: true

class PluggyItem::Syncer
  include SyncStats::Collector

  attr_reader :pluggy_item

  def initialize(pluggy_item)
    @pluggy_item = pluggy_item
  end

  def perform_sync(sync)
    Rails.logger.info "PluggyItem::Syncer - Starting sync for item #{pluggy_item.id}"

    # Phase 1: Import data from provider API
    sync.update!(status_text: I18n.t("pluggy_items.sync.status.importing")) if sync.respond_to?(:status_text)
    pluggy_item.import_latest_pluggy_data(sync: sync)

    # Phase 2: Collect setup statistics
    finalize_setup_counts(sync)

    # Phase 2.5: First-sync auto-setup — auto-create Accounts (with inferred
    # accountable types) for unlinked PluggyAccounts on the very first successful
    # sync, so the user can skip the manual setup wizard. Guarded by
    # has_completed_initial_setup? so it runs only while nothing is linked yet;
    # once accounts exist (linked here or manually), every later sync — including
    # new bank accounts the provider reports later — falls through to the wizard.
    # Phase 3 re-queries linked_pluggy_accounts, so accounts linked here flow into
    # process_accounts / schedule_account_syncs in the same sync cycle.
    perform_first_sync_auto_setup(sync) unless pluggy_item.has_completed_initial_setup?

    # Phase 3: Process data for linked accounts
    linked_pluggy_accounts = pluggy_item.linked_pluggy_accounts.includes(account_provider: :account)
    if linked_pluggy_accounts.any?
      sync.update!(status_text: I18n.t("pluggy_items.sync.status.processing")) if sync.respond_to?(:status_text)
      mark_import_started(sync)
      pluggy_item.process_accounts

      # Phase 4: Schedule balance calculations
      sync.update!(status_text: I18n.t("pluggy_items.sync.status.calculating")) if sync.respond_to?(:status_text)
      pluggy_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      # Phase 5: Collect statistics
      account_ids = linked_pluggy_accounts.filter_map { |pa| pa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "pluggy")
    end

    # A clean run means the item's credentials are healthy again.
    pluggy_item.update!(status: :good)

    # Mark sync health
    collect_health_stats(sync, errors: nil)
  rescue Provider::Pluggy::AuthenticationError => e
    pluggy_item.update!(status: :requires_update)
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
      sync.update!(status_text: I18n.t("pluggy_items.sync.status.importing_data")) if sync.respond_to?(:status_text)
    end

    def finalize_setup_counts(sync)
      sync.update!(status_text: I18n.t("pluggy_items.sync.status.checking_setup")) if sync.respond_to?(:status_text)

      unlinked_count = pluggy_item.unlinked_accounts_count

      if unlinked_count > 0
        pluggy_item.update!(pending_account_setup: true)
        sync.update!(status_text: I18n.t("pluggy_items.sync.status.needs_setup", count: unlinked_count)) if sync.respond_to?(:status_text)
      else
        pluggy_item.update!(pending_account_setup: false)
      end

      # Collect setup stats
      collect_setup_stats(sync, provider_accounts: pluggy_item.pluggy_accounts)
    end

    def perform_first_sync_auto_setup(sync)
      sync.update!(status_text: I18n.t("pluggy_items.sync.status.auto_setup")) if sync.respond_to?(:status_text)
      PluggyItem::AutoSetup.new(pluggy_item).call
    end
end
