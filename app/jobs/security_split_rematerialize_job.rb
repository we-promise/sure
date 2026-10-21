# Rebuilds one account's holdings and balances for one security after a split
# row changes (Security::Split.record!, #revise!, #remove!, .move!). A split is
# a fact about the security, so every account holding it, in any family, gets a
# job.
#
# A sync already running may have read the splits before the change committed,
# and Syncable#sync_later would not widen its window (Sync#expand_window_if_needed
# only widens a pending sync). So while the account has a sync running, even one
# asked to cancel, the job waits for it, then materialises on its own. A pending
# sync has read nothing yet and doesn't hold the job back.
class SecuritySplitRematerializeJob < ApplicationJob
  SyncInProgress = Class.new(StandardError)

  # Longer than Sync::VISIBLE_FOR: past that a sync is no longer visible, so the
  # job stops waiting for one whose worker was lost. If retries still run out,
  # the account is materialised anyway rather than left on the old figures.
  retry_on SyncInProgress, wait: 30.seconds, attempts: 20 do |job, _error|
    job.materialize(*job.arguments)
  end

  def perform(account, security)
    raise SyncInProgress if sync_running?(account)

    materialize(account, security)
  end

  # In the account's own family zone: the write that enqueued this ran in
  # whichever family's zone recorded the split, and the holding calculators
  # end their walk on Date.current. An unknown zone keeps the current one,
  # as Localize#resolved_timezone does.
  def materialize(account, security)
    zone = ActiveSupport::TimeZone[account.family.timezone.to_s] || Time.zone

    Time.use_zone(zone) do
      strategy = account.linked? ? :reverse : :forward
      Balance::Materializer.new(account, strategy: strategy, security_ids: [ security.id ]).materialize_balances
    end
  end

  private
    # Sync.visible also hides a sync asked to cancel, but one already running
    # finishes its work after the request (Sync#request_cancel!), so it is
    # still waited for. The VISIBLE_FOR bound stays: past it, the worker is
    # taken as lost.
    def sync_running?(account)
      account.syncs.where(status: "syncing").where("syncs.created_at > ?", Sync::VISIBLE_FOR.ago).exists?
    end
end
