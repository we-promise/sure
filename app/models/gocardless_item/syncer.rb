class GocardlessItem::Syncer
  include SyncStats::Collector

  attr_reader :gocardless_item

  def initialize(gocardless_item)
    @gocardless_item = gocardless_item
  end

  def perform_sync(sync)
    unless gocardless_item.bank_connected?
      gocardless_item.update!(status: :requires_update)
      raise StandardError, "GoCardless connection requires re-authorisation"
    end

    # Phase 1: Fetch raw data from GoCardless API and store on GocardlessAccount records
    sync.update!(status_text: "Importing data from GoCardless...") if sync.respond_to?(:status_text)
    import_result = gocardless_item.import_latest_gocardless_data

    # Only raise on auth failures (item marked :requires_update by importer).
    # Partial API failures (individual account endpoints down) are logged but
    # do not abort the sync — we process whatever data we have.
    if import_result[:accounts_updated] == 0 && import_result[:accounts_failed] > 0
      raise StandardError, import_result[:error] || "GoCardless import failed — all accounts unavailable"
    end

    # Phase 2: Flag any unlinked accounts so the user can set them up
    gocardless_item.update!(pending_account_setup: gocardless_item.gocardless_accounts.unlinked.any?)

    collect_setup_stats(sync, provider_accounts: gocardless_item.gocardless_accounts.active)

    # Phase 3: Process stored raw data into Account balances and Entry records
    linked_account_ids = gocardless_item.gocardless_accounts
                                        .joins(:account_provider)
                                        .joins(:account)
                                        .merge(Account.visible)
                                        .pluck("accounts.id")

    if linked_account_ids.any?
      sync.update!(status_text: "Processing accounts...") if sync.respond_to?(:status_text)
      gocardless_item.process_accounts

      collect_transaction_stats(sync, account_ids: linked_account_ids, source: "gocardless")

      # Phase 4: Schedule balance recalculations for each linked account
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      gocardless_item.schedule_account_syncs(
        parent_sync:       sync,
        window_start_date: sync.window_start_date,
        window_end_date:   sync.window_end_date
      )
    end

    collect_health_stats(sync, errors: nil)

  rescue Provider::Gocardless::RateLimitError => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "rate_limit" } ], rate_limited: true, rate_limited_at: Time.current)
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
    # no-op
  end
end
