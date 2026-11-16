# Syncs a connection once it has no sync left unfinished, for callers that
# need a fresh sync rather than reusing a running one (whose import may
# already be past the data they changed). Every unfinished sync counts,
# including one past the window in which `sync_later` would still reuse it,
# since a new sync would overlap it.
#
# If syncs are still unfinished after the last attempt, it records that and
# does not sync: the connection's own schedule syncs it next time, and
# Sync.clean marks a sync whose job was lost as stale.
class FollowUpSyncJob < ApplicationJob
  queue_as :high_priority

  RETRY_DELAY = 1.minute
  MAX_ATTEMPTS = 60

  def perform(syncable, attempts_remaining: MAX_ATTEMPTS)
    unless syncable.syncs.incomplete.exists?
      syncable.sync_later
      return
    end

    if attempts_remaining.positive?
      self.class.set(wait: RETRY_DELAY).perform_later(syncable, attempts_remaining: attempts_remaining - 1)
      return
    end

    DebugLogEntry.capture(
      category: "background_jobs",
      level: "warn",
      message: "Gave up waiting for #{syncable.class.name} #{syncable.id} to finish its unfinished syncs; left to its next scheduled sync",
      source: self.class.name,
      provider_key: syncable.class.name.delete_suffix("Item").underscore.presence,
      family: syncable.try(:family),
      metadata: {
        syncable_type: syncable.class.name,
        syncable_id: syncable.id,
        unfinished_sync_ids: syncable.syncs.incomplete.pluck(:id)
      }
    )
  end
end
