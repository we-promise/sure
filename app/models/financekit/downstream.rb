class Financekit::Downstream
  def initialize(batches)
    @batches = Array(batches)
  end

  def perform!
    @batches.reject(&:downstream_completed_at?).group_by(&:financekit_item_id).each_value do |batches|
      fan_out!(batches)
    end
  end

  private

    # Account syncs, transfer matching and rule application all cost the same
    # whether one capture or fifty just landed, so a drain pays for them once
    # rather than once per capture.
    def fan_out!(batches)
      item = batches.first.financekit_item
      item.selected_accounts.includes(financekit_account_lineage: :account).find_each do |mapping|
        mapping.account&.sync_later
      end
      item.family.auto_match_transfers!
      item.family.rules.where(active: true).find_each(&:apply_later)
      completed_at = Time.current
      FinancekitBatch.where(id: batches.map(&:id))
        .update_all(downstream_completed_at: completed_at, updated_at: completed_at)
      item.update!(last_downstream_at: completed_at)
    rescue StandardError
      DebugLogEntry.capture(category: "provider_sync", level: "error",
        message: "FinanceKit downstream scheduling failed", source: self.class.name,
        provider_key: "financekit", family: item&.family,
        metadata: { batch_ids: batches.map(&:batch_id) })
    end
end
