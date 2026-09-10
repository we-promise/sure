class Financekit::Downstream
  def initialize(batch)
    @batch = batch
  end

  def perform!
    # Keep a persistent outbox until the standard sync records have completed.
    # A failed or lost SyncJob is retried by sync_later after its visibility lease.
    @batch.with_lock do
      return if @batch.downstream_completed_at
      return if @batch.downstream_retry_at && @batch.downstream_retry_at > Time.current
      item = @batch.financekit_item
      accounts = item.financekit_accounts.includes(:account).filter_map(&:account)
      completed = accounts.all? do |account|
        account.syncs.completed.where("created_at >= ?", @batch.applied_at).exists?
      end
      unless completed
        accounts.each { |account| account.sync_later }
        return
      end
      # Use configured Sure rules (including configured enrichment destinations).
      # The outbox may replay after a crash; standard rules retain their own
      # enrichment protections and asynchronous RuleRun accounting.
      item.family.auto_match_transfers!
      pending_rules = item.family.rules.where(active: true).reject do |rule|
        rule.rule_runs.successful.where("executed_at >= ?", @batch.applied_at).exists?
      end
      if pending_rules.empty?
        @batch.update!(downstream_completed_at: Time.current, downstream_retry_at: nil)
      else
        # Enqueue success is not completion. Keep the outbox until RuleRun
        # acknowledges success, including asynchronous enrichment jobs. A lost
        # queue entry or abandoned pending run is retried after the lease.
        pending_rules.each(&:apply_later)
        @batch.update!(downstream_retry_at: 5.minutes.from_now)
      end
    end
  end
end
