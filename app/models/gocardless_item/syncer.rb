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

    # Phase 1: Import data
    sync.update!(status_text: "Importing data from GoCardless...") if sync.respond_to?(:status_text)
    import_result = gocardless_item.import_latest_gocardless_data

    unless import_result[:success]
      raise StandardError, import_result[:error] || "GoCardless import failed"
    end

    # Phase 2: Check for unlinked accounts
    unlinked = gocardless_item.gocardless_accounts
                              .left_joins(:account_provider)
                              .where(account_providers: { id: nil })

    if unlinked.any?
      gocardless_item.update!(pending_account_setup: true)
    else
      gocardless_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process and schedule balance recalculations
    linked_account_ids = gocardless_item.gocardless_accounts
                                        .joins(:account_provider)
                                        .joins(:account)
                                        .merge(Account.visible)
                                        .pluck("accounts.id")

    if linked_account_ids.any?
      sync.update!(status_text: "Processing accounts...") if sync.respond_to?(:status_text)
      gocardless_item.process_accounts

      collect_transaction_stats(sync, account_ids: linked_account_ids, source: "gocardless")

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      gocardless_item.schedule_account_syncs(
        parent_sync:       sync,
        window_start_date: sync.window_start_date,
        window_end_date:   sync.window_end_date
      )
    end

    collect_health_stats(sync, errors: nil)

  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
    # no-op
  end
end