# Sends the "sync finished, refresh the page" toast once per batch of syncs.
#
# Syncing several connections (or "Sync all") finishes one sync after another.
# Every finished sync schedules this job; only the newest one does anything, and
# it waits while other syncs of the family are still visibly running. The
# decision does not depend on any other sync ever reporting back, so a sync
# whose worker died can delay the toast by at most Sync::VISIBLE_FOR.
class FamilySyncToastJob < ApplicationJob
  include FamilyDebounce

  queue_as :default
  self.debounce_key_prefix = "family_sync_toast"

  # Debounce window after the last finished sync.
  DEBOUNCE_DELAY = 10.seconds

  # How long to wait before looking again while other syncs are still running.
  RECHECK_DELAY = 15.seconds

  # Upper bound for rechecks, a little longer than Sync::VISIBLE_FOR.
  MAX_RECHECKS = 24

  # Far beyond any queue backlog or retry of the recheck chain, so a late
  # delivery still finds the newest token and stands down. The key is tiny.
  TOKEN_TTL = 1.day

  def self.schedule_for(family)
    token = claim_debounce_token(family.id, expires_in: TOKEN_TTL)
    set(wait: DEBOUNCE_DELAY).perform_later(family.id, token)
  end

  def perform(family_id, token, recheck = 0)
    family = Family.find_by(id: family_id)
    return unless family

    # A sync finished after this job was scheduled: its job takes over.
    return if superseded?(family_id, token)

    # Sync.visible ignores syncs started more than Sync::VISIBLE_FOR ago and
    # cancelled ones, so this loop ends even if a worker died mid-sync;
    # MAX_RECHECKS is only a safety net.
    if recheck < MAX_RECHECKS && Sync.for_family(family).visible.exists?
      self.class.set(wait: RECHECK_DELAY).perform_later(family_id, token, recheck + 1)
      return
    end

    family.broadcast_replace_to(
      family,
      target: "sync-toast",
      partial: "shared/notifications/sync_toast"
    )
  end
end
