class EnableBankingItem::Syncer
  include SyncStats::Collector

  attr_reader :enable_banking_item

  def initialize(enable_banking_item)
    @enable_banking_item = enable_banking_item
  end

  def perform_sync(sync)
    psu_context = nil

    begin
      enable_banking_item.reload
      enable_banking_item.with_sync_lock do
        enable_banking_item.reload
        psu_context = enable_banking_item.consume_psu_context!(sync)
        perform_import(sync, psu_context: psu_context)
      end
    rescue EnableBankingItem::SyncScheduling::SyncDeferredError => e
      enable_banking_item.consume_psu_context!(sync)
      record_deferred_sync(sync, reason: "bank_sync_in_progress", message: e.message)
    ensure
      enable_banking_item.release_sync_reservation!(sync)
    end
  end

  def perform_import(sync, psu_context: nil)
    unless enable_banking_item.session_valid?
      sync.update!(status_text: "Session expired - re-authorization required") if sync.respond_to?(:status_text)
      enable_banking_item.update!(status: :requires_update)
      collect_health_stats(sync, errors: nil)
      return
    end

    unless enable_banking_item.has_visible_linked_accounts?
      enable_banking_item.refresh_pending_account_setup!
      stats = (sync.reload.sync_stats || {}).deep_stringify_keys
      stats["catalog_only"] = true
      stats["catalog_accounts"] = enable_banking_item.enable_banking_accounts.count
      stats["deferred_reason"] = "account_setup_required"
      sync.update!(sync_stats: stats)
      collect_health_stats(sync, errors: nil)
      return
    end

    reservation = enable_banking_item.reserve_sync_slot!(sync: sync, psu_context: psu_context)
    if reservation == :invalid_session
      # an expired/missing session is an expected state that needs user action,
      # not a hard failure.
      sync.update!(status_text: "Session expired - re-authorization required") if sync.respond_to?(:status_text)
      enable_banking_item.update!(status: :requires_update)
      collect_health_stats(sync, errors: nil)
      return
    end

    unless reservation
      record_deferred_sync(sync, reason: deferred_reason, retry_at: enable_banking_item.sync_retry_at)
      return
    end

    # Phase 1: Import data from Enable Banking API
    sync.update!(status_text: "Importing accounts from Enable Banking...") if sync.respond_to?(:status_text)
    import_result = enable_banking_item.import_latest_enable_banking_data(
      psu_headers: reservation.fetch(:psu_headers),
      sync_budget: enable_banking_item.enable_banking_sync_budget
    )

    unless import_result[:success]
      # A session-level auth failure detected mid-import flips the item to
      # requires_update — surface that as a graceful reconnect state, not a red
      # error. Transient/per-account failures leave status good and fall through
      # to a normal sync error that retries next time.
      if enable_banking_item.requires_update?
        sync.update!(status_text: "Re-authorization required") if sync.respond_to?(:status_text)
        collect_health_stats(sync, errors: nil)
        return
      end

      error_msg = import_result[:error]
      if error_msg.blank? && (import_result[:accounts_failed].to_i > 0 || import_result[:transactions_failed].to_i > 0)
        parts = []
        parts << "#{import_result[:accounts_failed]} #{'account'.pluralize(import_result[:accounts_failed])} failed" if import_result[:accounts_failed].to_i > 0
        parts << "#{import_result[:transactions_failed]} #{'transaction'.pluralize(import_result[:transactions_failed])} failed" if import_result[:transactions_failed].to_i > 0
        error_msg = parts.join(", ")
      end
      raise StandardError.new(error_msg.presence || "Import failed")
    end

    partial_import_counts = {
      "accounts_failed" => import_result[:accounts_failed].to_i,
      "balances_failed" => import_result[:balances_failed].to_i,
      "transactions_failed" => import_result[:transactions_failed].to_i
    }
    process_failures = 0

    # Phase 2: Check account setup status and collect sync statistics
    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: enable_banking_item.enable_banking_accounts.includes(:account_provider, :account))

    unlinked_accounts = enable_banking_item.enable_banking_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    if unlinked_accounts.any?
      enable_banking_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      enable_banking_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process transactions for linked and visible accounts only
    linked_account_ids = enable_banking_item.enable_banking_accounts
      .joins(:account_provider)
      .joins(:account)
      .merge(Account.visible)
      .pluck("accounts.id")

    if linked_account_ids.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      process_results = enable_banking_item.process_accounts
      process_failures = process_results.count { |result| result[:success] == false }

      # Collect transaction statistics
      collect_transaction_stats(sync, account_ids: linked_account_ids, source: "enable_banking")

      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      enable_banking_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    end

    if partial_import_counts.values.none?(&:positive?) && process_failures.to_i.zero?
      enable_banking_item.update!(last_successful_sync_at: Time.current)
      stats = (sync.reload.sync_stats || {}).deep_stringify_keys
      stats["data_import_success"] = true
      sync.update!(sync_stats: stats)
    end
    enable_banking_item.update!(sync_retry_count: 0, sync_retry_reason: nil)
    collect_health_stats(sync, errors: nil)
    partial_import_counts["account_processing_failed"] = process_failures if process_failures.positive?
    record_partial_import(sync, partial_import_counts) if partial_import_counts.values.any?(&:positive?)
  rescue Provider::EnableBanking::EnableBankingError => e
    if e.retryable? && enable_banking_item.schedule_sync_retry!(e)
      record_deferred_sync(
        sync,
        reason: e.rate_limited? ? "rate_limited" : "temporary_error",
        retry_at: enable_banking_item.sync_retry_at,
        rate_limited: e.rate_limited?
      )
      return
    end

    enable_banking_item.update!(sync_retry_count: 0, sync_retry_reason: nil)
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  rescue => e
    unless e.is_a?(EnableBankingItem::SyncScheduling::SyncDeferredError)
      enable_banking_item.update!(sync_retry_count: 0, sync_retry_reason: nil)
    end
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def record_deferred_sync(sync, reason:, message: nil, retry_at: nil, rate_limited: false)
    collect_health_stats(sync, errors: nil, rate_limited: rate_limited, rate_limited_at: rate_limited ? Time.current : nil)
    stats = (sync.reload.sync_stats || {}).merge(
      "deferred" => true,
      "deferred_reason" => reason,
      "retry_at" => retry_at&.iso8601,
      "deferred_message" => message
    ).compact
    sync.update!(sync_stats: stats)
  end

  def record_partial_import(sync, counts)
    stats = (sync.reload.sync_stats || {}).deep_stringify_keys
    partial_counts = (stats["partial_import_counts"] || {}).merge(counts.stringify_keys)
    stats["partial_import"] = true
    stats["partial_import_counts"] = partial_counts
    stats["total_errors"] = partial_counts.values.sum
    sync.update!(sync_stats: stats)
  end

  def deferred_reason
    if enable_banking_item.sync_rate_limited?
      "rate_limited"
    elsif enable_banking_item.next_background_sync_at.present? && enable_banking_item.next_background_sync_at > Time.current
      "background_pacing"
    else
      "item_pacing"
    end
  end

  def perform_post_sync
    # no-op
  end
end
