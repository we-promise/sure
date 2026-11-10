class EntryScheduledSyncJob < ApplicationJob
  # Scheduled (future-dated) entries are excluded from balance calculations
  # until their date arrives (see Entry#scheduled?, Balance::SyncCache). That
  # normally happens on the next sync -- but if host-wide auto-sync
  # (Setting.auto_sync_enabled) and the family's auto_sync_on_login are both
  # disabled, nothing would otherwise trigger a sync on that date. This job
  # is the fallback: it fires once, on the entry's date, and simply asks the
  # account to sync -- a cheap no-op if a sync already happened by then.
  def perform(entry_id, account_id = nil)
    entry = Entry.find_by(id: entry_id)
    return entry.account.sync_later if entry

    # The representative entry was deleted after the job was scheduled; the
    # other entries on that account and date still need their sync.
    Account.find_by(id: account_id)&.sync_later if account_id
  end

  def self.schedule_for(entry)
    # "Future" is judged in the family's zone: entries are scheduled from jobs
    # running in the app's zone, where Date.current may already be the
    # entry's date even though it is still tomorrow for the family.
    Time.use_zone(entry.account.family.resolved_time_zone) do
      return unless entry.scheduled?

      # A few minutes past midnight on the entry's date, so Date.current has
      # definitively rolled over (avoids clock-skew edge cases) by run time.
      # Midnight in the family's zone, as Sync#perform judges the date there.
      run_at = entry.date.in_time_zone(entry.account.family.resolved_time_zone) + 5.minutes
      set(wait_until: run_at).perform_later(entry.id, entry.account_id)
    end
  end

  # Batch variant for paths that write many entries without going through
  # Entry#sync_account_later (imports, bulk updates). Enqueues one job per
  # (account, date) -- they'd all sync the same account on the same day.
  # The date filter lives in schedule_for: "future" depends on the family's
  # time zone, so it cannot be judged once for the whole batch in SQL.
  def self.schedule_for_entries(entries)
    entries.select("DISTINCT ON (entries.account_id, entries.date) entries.*")
           .order("entries.account_id, entries.date")
           .each { |entry| schedule_for(entry) }
  end
end
