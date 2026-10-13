class Financekit::Downstream
  def initialize(batch)
    @batch = batch
  end

  def perform!
    return if @batch.downstream_completed_at?

    item = @batch.financekit_item
    item.selected_accounts.includes(financekit_account_lineage: :account).find_each do |mapping|
      mapping.account&.sync_later
    end
    item.family.auto_match_transfers!
    item.family.rules.where(active: true).find_each(&:apply_later)
    completed_at = Time.current
    @batch.update!(downstream_completed_at: completed_at)
    item.update!(last_downstream_at: completed_at)
  rescue StandardError
    DebugLogEntry.capture(category: "provider_sync", level: "error",
      message: "FinanceKit downstream scheduling failed", source: self.class.name,
      provider_key: "financekit", family: @batch.financekit_item.family,
      metadata: { batch_id: @batch.batch_id })
  end
end
