class EntryScheduledSyncJob < ApplicationJob
  # Scheduled (future-dated) entries are excluded from balance calculations
  # until their date arrives (see Entry#scheduled?, Balance::SyncCache). That
  # normally happens on the next sync -- but if host-wide auto-sync
  # (Setting.auto_sync_enabled) and the family's auto_sync_on_login are both
  # disabled, nothing would otherwise trigger a sync on that date. This job
  # is the fallback: it fires once, on the entry's date, and simply asks the
  # account to sync -- a cheap no-op if a sync already happened by then.
  def perform(entry_id)
    entry = Entry.find_by(id: entry_id)
    return unless entry

    entry.account.sync_later
  end

  def self.schedule_for(entry)
    return unless entry.scheduled?

    # A few minutes past midnight on the entry's date, so Date.current has
    # definitively rolled over (avoids clock-skew edge cases) by run time.
    run_at = entry.date.beginning_of_day + 5.minutes
    set(wait_until: run_at).perform_later(entry.id)
  end
end
