class Financekit::Downstream
  # Takes a scope rather than loaded records and keeps only the ids. A pending
  # batch carries its payload — up to Financekit::MAX_BYTES, retained for seven
  # days — and an applied batch no longer counts against the inbox cap, so a
  # backlog awaiting downstream work has no ceiling of its own. Snapshotting the
  # ids up front also stops a capture applied concurrently from being marked
  # done without a fan-out of its own.
  def initialize(item, scope)
    @item = item
    @batch_ids = scope.where(downstream_completed_at: nil).pluck(:id)
  end

  def perform!
    return if @batch_ids.empty?

    # Account syncs, transfer matching and rule application all cost the same
    # whether one capture or fifty just landed, so a drain pays for them once
    # rather than once per capture.
    @item.selected_accounts.includes(financekit_account_lineage: :account).find_each do |mapping|
      mapping.account&.sync_later
    end
    @item.family.auto_match_transfers!
    @item.family.rules.where(active: true).find_each(&:apply_later)
    completed_at = Time.current
    FinancekitBatch.where(id: @batch_ids)
      .update_all(downstream_completed_at: completed_at, updated_at: completed_at)
    @item.update!(last_downstream_at: completed_at)
  rescue StandardError
    DebugLogEntry.capture(category: "provider_sync", level: "error",
      message: "FinanceKit downstream scheduling failed", source: self.class.name,
      provider_key: "financekit", family: @item.family,
      metadata: { financekit_item_id: @item.id, batches: @batch_ids.size })
  end
end
