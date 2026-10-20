# Rebuilds one account's holdings and balances for one security after a split
# row changes (Security::Split.record!, #revise!, #remove!). A split is a fact
# about the security, so every account holding it, in any family, gets a job.
#
# A sync already running may have read the splits before the change committed,
# and Syncable#sync_later would not widen its window (Sync#expand_window_if_needed
# only widens a pending sync). So while the account has a visible sync in
# progress the job waits for it, then materialises on its own. A pending sync
# has read nothing yet and doesn't hold the job back.
class SecuritySplitRematerializeJob < ApplicationJob
  SyncInProgress = Class.new(StandardError)

  # Longer than Sync::VISIBLE_FOR: past that a sync is no longer visible, so the
  # job stops waiting for one whose worker was lost. If retries still run out,
  # the account is materialised anyway rather than left on the old figures.
  retry_on SyncInProgress, wait: 30.seconds, attempts: 20 do |job, _error|
    job.materialize(*job.arguments)
  end

  def perform(account, security)
    raise SyncInProgress if account.syncs.visible.where(status: "syncing").exists?

    materialize(account, security)
  end

  def materialize(account, security)
    strategy = account.linked? ? :reverse : :forward
    Balance::Materializer.new(account, strategy: strategy, security_ids: [ security.id ]).materialize_balances
  end
end
