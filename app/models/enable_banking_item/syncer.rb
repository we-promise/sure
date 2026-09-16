class EnableBankingItem::Syncer
  include SyncStats::Collector

  attr_reader :enable_banking_item

  def initialize(enable_banking_item)
    @enable_banking_item = enable_banking_item
    @original_context = EnableBankingItem::LegacyAccess.transport_context(enable_banking_item)
  end

  def perform_sync(sync)
    EnableBankingItem::LegacyAccess.with_item(enable_banking_item, operation: :ingest, sync: sync) do |current, current_sync|
      raise EnableBankingItem::LegacyAccess::Fence::InvalidSource, "Enable Banking coordination requires its original Sync" unless current_sync
      EnableBankingItem::LegacyAccess.verify_transport!(current, @original_context)
      EnableBankingItem::LegacyAccess.assert_transport!
      self.class.new(current).send(:perform_sync_admitted, current_sync)
    end
  end

  private def perform_sync_admitted(sync)
    @item_context = EnableBankingItem::LegacyAccess.transport_context(enable_banking_item)
    # An expired/missing session is an expected state that needs user action, not a
    # hard failure. Mark the connection requires_update and finish the sync
    # gracefully so the UI surfaces the "Reconnect" CTA instead of a red sync error.
    unless enable_banking_item.session_valid?
      with_progress(sync) do |current, item|
        current.update!(status_text: "Session expired - re-authorization required")
        item.update!(status: :requires_update)
      end
      collect_health_stats(sync, errors: nil)
      return
    end

    # Phase 1: Import data from Enable Banking API
    update_status(sync, "Importing accounts from Enable Banking...")
    import_result = enable_banking_item.import_latest_enable_banking_data
    @item_context = import_result[:admitted_transport_context] || @item_context
    enable_banking_item.reload

    unless import_result[:success]
      # A session-level auth failure detected mid-import flips the item to
      # requires_update — surface that as a graceful reconnect state, not a red
      # error. Transient/per-account failures leave status good and fall through
      # to a normal sync error that retries next time.
      if enable_banking_item.requires_update?
        update_status(sync, "Re-authorization required")
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

    # Phase 2: Check account setup status and collect sync statistics
    update_status(sync, "Checking account configuration...")
    setup_sources = enable_banking_item.enable_banking_accounts.select(:id, :enable_banking_item_id)
      .includes(:account_provider, :account).limit(EnableBankingItem::LegacyAccess::MAX_ACCOUNTS + 1).to_a
    if setup_sources.size > EnableBankingItem::LegacyAccess::MAX_ACCOUNTS
      raise EnableBankingItem::LegacyAccess::Fence::InvalidSource, "Enable Banking setup inventory exceeds its bound"
    end
    collect_setup_stats(sync, provider_accounts: setup_sources)

    unlinked_accounts = enable_banking_item.enable_banking_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    unlinked_count = unlinked_accounts.count
    with_progress(sync) do |current, item|
      item.update!(pending_account_setup: unlinked_count.positive?)
      current.update!(status_text: "#{unlinked_count} accounts need setup...") if unlinked_count.positive?
    end

    # Phase 3: Process transactions for linked and visible accounts only
    linked_account_ids = enable_banking_item.enable_banking_accounts
      .joins(:account_provider)
      .joins(:account)
      .merge(Account.visible)
      .pluck("accounts.id")

    if linked_account_ids.any?
      update_status(sync, "Processing transactions...")
      refuse_failed_results!(enable_banking_item.process_accounts(expected_contexts: import_result[:admitted_source_contexts],
        expected_item_context: @item_context))

      # Collect transaction statistics
      collect_transaction_stats(sync, account_ids: linked_account_ids, source: "enable_banking")

      # Phase 4: Schedule balance calculations for linked accounts
      update_status(sync, "Calculating balances...")
      refuse_failed_results!(enable_banking_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      ))
    end

    collect_health_stats(sync, errors: nil)
  rescue *EnableBankingItem::LegacyAccess::DENIAL_ERRORS
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
    # no-op
  end

  private

    def update_status(sync, message)
      with_progress(sync) { |current, _item| current.update!(status_text: message) }
    end

    def merge_sync_stats(sync, new_stats)
      with_progress(sync) { |current, _item| current.update!(sync_stats: (current.sync_stats || {}).merge(new_stats)) }
    end

    def with_progress(sync)
      EnableBankingItem::LegacyAccess.with_snapshot(enable_banking_item, expected_context: @item_context) do |fresh|
        current = EnableBankingItem::LegacyAccess::Fence.scoped_sync!(fresh, sync)
        current.lock!("FOR UPDATE NOWAIT")
        EnableBankingItem::LegacyAccess::Fence.scoped_sync!(fresh, current)
        yield current, fresh
      end
    rescue ActiveRecord::RecordNotFound
      raise EnableBankingItem::LegacyAccess::Fence::OwnershipChanged, "Enable Banking progress owner changed", cause: nil
    rescue ActiveRecord::LockWaitTimeout
      raise EnableBankingItem::LegacyAccess::Fence::Busy, "Enable Banking progress is being changed", cause: nil
    end

    def refuse_failed_results!(results)
      if Array(results).any? { |result| result.is_a?(Hash) && result.with_indifferent_access[:success] == false }
        raise StandardError, "Enable Banking account processing did not finish"
      end
    end
end
