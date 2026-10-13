# Sends the "sync finished, refresh the page" toast once per batch of syncs.
#
# Syncing several connections (or "Sync all") finishes one sync after another.
# Every finished sync schedules this job; only the newest one does anything, and
# it waits while other syncs of the family are still visibly running. The
# decision does not depend on any other sync ever reporting back, so a sync
# whose worker died can delay the toast by at most Sync::VISIBLE_FOR.
class FamilySyncToastJob < ApplicationJob
  queue_as :default

  # Debounce window after the last finished sync.
  DEBOUNCE_DELAY = 10.seconds

  # How long to wait before looking again while other syncs are still running.
  RECHECK_DELAY = 15.seconds

  # Upper bound for rechecks, a little longer than Sync::VISIBLE_FOR.
  MAX_RECHECKS = 24

  def self.schedule_for(family)
    scheduled_at = Time.current.to_f

    # Outlives the longest recheck chain, so a delayed older run still sees it.
    Rails.cache.write(cache_key(family.id), scheduled_at, expires_in: DEBOUNCE_DELAY + RECHECK_DELAY * MAX_RECHECKS + 5.minutes)
    set(wait: DEBOUNCE_DELAY).perform_later(family.id, scheduled_at)
  end

  def self.cache_key(family_id)
    "family_sync_toast:#{family_id}"
  end

  def perform(family_id, scheduled_at, recheck = 0)
    family = Family.find_by(id: family_id)
    return unless family

    # A sync finished after this job was scheduled: its job takes over.
    latest_scheduled = Rails.cache.read(self.class.cache_key(family_id))
    return if latest_scheduled && latest_scheduled > scheduled_at

    # Sync.visible ignores syncs started more than Sync::VISIBLE_FOR ago and
    # cancelled ones, so this loop ends even if a worker died mid-sync;
    # MAX_RECHECKS is only a safety net.
    if recheck < MAX_RECHECKS && Sync.for_family(family).visible.exists?
      self.class.set(wait: RECHECK_DELAY).perform_later(family_id, scheduled_at, recheck + 1)
      return
    end

    family.broadcast_replace_to(
      family,
      target: "sync-toast",
      partial: "shared/notifications/sync_toast"
    )
  end
end
