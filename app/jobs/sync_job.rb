class SyncJob < ApplicationJob
  queue_as :high_priority

  # Another job is running a sync for the same syncable. The sync is still
  # pending, so retrying runs it after the other one finishes and never drops
  # the request. Bounded in practice: once the sync is no longer pending
  # (completed elsewhere, cancelled or marked stale after 24h) perform no-ops.
  CONCURRENT_RETRY_WAIT = 30.seconds
  retry_on Sync::ConcurrentSyncError, wait: CONCURRENT_RETRY_WAIT, attempts: :unlimited

  # A holder that hangs (not crashed, so its lock is never released) keeps the
  # waiter retrying until SyncCleanerJob marks it stale. Surface that roughly
  # once an hour instead of on every attempt.
  LONG_WAIT_THRESHOLD = 1.hour
  LONG_WAIT_REPORT_EVERY = (LONG_WAIT_THRESHOLD / CONCURRENT_RETRY_WAIT).to_i

  # Accept a runtime-only flag to influence sync behavior without persisting config
  def perform(sync, balances_only: false)
    # Attach a transient predicate for this execution only
    begin
      sync.define_singleton_method(:balances_only?) { balances_only }
    rescue => e
      Rails.logger.warn("SyncJob: failed to attach balances_only? flag: #{e.class} - #{e.message}")
    end

    # Heartbeat for Sync.joinable: shows this pending sync still has a live job.
    sync.update_column(:last_attempted_at, Time.current) if sync.pending?

    begin
      sync.perform
    rescue Sync::ConcurrentSyncError
      report_long_wait(sync)
      raise
    end
  end

  private
    def report_long_wait(sync)
      waiting_for = Time.current - sync.created_at
      return unless waiting_for > LONG_WAIT_THRESHOLD && (executions % LONG_WAIT_REPORT_EVERY).zero?

      syncable = sync.syncable
      DebugLogEntry.capture(
        category: "sync",
        level: "warn",
        message: "Sync #{sync.id} has waited #{(waiting_for / 1.hour).floor}h for another sync of #{sync.syncable_type}##{sync.syncable_id} to finish",
        source: self.class.name,
        family: syncable.is_a?(Family) ? syncable : syncable.try(:family),
        metadata: { sync_id: sync.id, syncable_type: sync.syncable_type, syncable_id: sync.syncable_id, attempts: executions }
      )
    end
end
