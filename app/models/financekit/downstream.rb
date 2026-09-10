class Financekit::Downstream
  def initialize(batch)
    @batch = batch
  end

  def perform!
    # Keep a persistent outbox until the standard sync records have completed.
    # A failed or lost SyncJob is retried by sync_later after its visibility lease.
    @batch.with_lock do
      return if @batch.downstream_completed_at
      item = @batch.financekit_item
      accounts = item.financekit_accounts.includes(:account).filter_map(&:account)
      completed = accounts.all? do |account|
        account.syncs.completed.where("completed_at >= ?", @batch.applied_at).exists?
      end
      unless completed
        accounts.each { |account| account.sync_later }
        return
      end
      # Use configured Sure rules (including configured enrichment destinations).
      # The outbox may replay after a crash; standard rules retain their own
      # enrichment protections and asynchronous RuleRun accounting.
      item.family.auto_match_transfers!
      item.family.rules.where(active: true).find_each(&:apply_later)
      @batch.update!(downstream_completed_at: Time.current)
    end
  end
end
