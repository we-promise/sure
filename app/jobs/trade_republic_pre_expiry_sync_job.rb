# A Trade Republic session ends 24 hours after login, whatever time the daily
# auto-sync runs. One sync shortly before the end picks up the day's activity
# while the session still works.
class TradeRepublicPreExpirySyncJob < ApplicationJob
  queue_as :scheduled

  LEAD_TIME = 1.hour

  def self.schedule_for(item)
    run_at = item.session_expires_at - LEAD_TIME
    return if run_at.past?

    set(wait_until: run_at).perform_later(item, session_expires_at: item.session_expires_at.to_i)
  end

  def perform(item, session_expires_at:)
    # A newer login has scheduled its own sync.
    return unless item.session_expires_at&.to_i == session_expires_at
    return if item.scheduled_for_deletion? || item.syncing? || !item.ready_for_sync?

    item.sync_later
  end
end
