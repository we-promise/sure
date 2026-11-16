# Syncs a connection once the sync it already has running finishes, for
# callers that need a fresh sync rather than reusing the running one (whose
# import may already be past the data they changed). It waits on any
# unfinished sync, including one past the window in which `sync_later` would
# still reuse it, since that sync may still be running.
class FollowUpSyncJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 10.seconds
  MAX_ATTEMPTS = 36

  def perform(syncable, active_sync_id:, attempts_remaining: MAX_ATTEMPTS)
    if syncable.syncs.incomplete.exists?(id: active_sync_id)
      if attempts_remaining.positive?
        self.class.set(wait: RETRY_DELAY).perform_later(
          syncable,
          active_sync_id: active_sync_id,
          attempts_remaining: attempts_remaining - 1
        )
        return
      end

      DebugLogEntry.capture(
        category: "background_jobs",
        level: "warn",
        message: "Gave up waiting for #{syncable.class.name} #{syncable.id} sync #{active_sync_id} to finish",
        source: self.class.name,
        provider_key: syncable.class.name.delete_suffix("Item").underscore.presence,
        family: syncable.try(:family),
        metadata: { syncable_type: syncable.class.name, syncable_id: syncable.id, active_sync_id: active_sync_id }
      )
    end

    syncable.sync_later
  end
end
