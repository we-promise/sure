class Financekit::Downstream
  def initialize(batch)
    @batch = batch
  end

  def perform!
    return if @batch.downstream_completed_at?

    item = @batch.financekit_item
    account_provider = nil
    item.selected_accounts.includes(financekit_account_lineage: [ :account, :account_provider ]).find_each do |mapping|
      account_provider = mapping.financekit_account_lineage.account_provider
      mapping.account&.sync_later
    end
    account_provider = nil
    item.family.auto_match_transfers!
    item.family.rules.where(active: true).find_each(&:apply_later)
    completed_at = Time.current
    @batch.update!(downstream_completed_at: completed_at)
    item.update!(last_downstream_at: completed_at)
    Financekit::Diagnostics.capture(item: item, batch: @batch, source: self.class.name,
      message: "FinanceKit downstream scheduling completed", event: "downstream_completed")
  rescue StandardError => error
    Financekit::Diagnostics.capture(item: @batch.financekit_item, batch: @batch, source: self.class.name,
      level: "error", message: "FinanceKit downstream scheduling failed", event: "downstream_failed",
      account_provider: account_provider, error_class: error.class.name)
  end
end
