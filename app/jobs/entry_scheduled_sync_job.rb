class EntryScheduledSyncJob < ApplicationJob
  # Scheduled (future-dated) entries are excluded from balance calculations
  # until their date arrives (see Entry#scheduled?, Balance::SyncCache). That
  # normally happens on the next sync -- but if host-wide auto-sync
  # (Setting.auto_sync_enabled) and the family's auto_sync_on_login are both
  # disabled, nothing would otherwise trigger a sync on that date. This job
  # is the fallback: it fires once, on the entry's date, and simply asks the
  # account to sync -- a cheap no-op if a sync already happened by then.
  def perform(account_id, date)
    account = Account.find_by(id: account_id)
    return unless account

    account.sync_later
  end

  def self.schedule_for(entry)
    family = entry.account.family
    return unless Time.use_zone(family.resolved_time_zone) { entry.scheduled? }

    account = entry.account
    run_at = entry.date.in_time_zone(family.resolved_time_zone) + 5.minutes
    set(wait_until: run_at).perform_later(account.id, entry.date)
  end

  # Batch variant for paths that write many entries without going through
  # Entry#sync_account_later (imports, bulk updates). Enqueues one job per
  # (account, date): perform(account_id, date) syncs the whole account, so
  # deleting one entry in the batch does not cancel the sync for the others.
  # "Future" is judged in each entry's family time zone, so entries dated
  # tomorrow for a west-of-UTC family are not skipped by a job running in the
  # app's zone.
  def self.schedule_for_entries(entries)
    entries = entries.to_a
    return if entries.empty?

    entries.group_by { |entry| entry.account.family }.each do |family, family_entries|
      Time.use_zone(family.resolved_time_zone) do
        family_entries.select { |entry| entry.date > Date.current }
          .group_by(&:account_id)
          .each do |account_id, account_entries|
            account_entries.map(&:date).uniq.each do |date|
              run_at = date.in_time_zone(family.resolved_time_zone) + 5.minutes
              set(wait_until: run_at).perform_later(account_id, date)
            end
          end
      end
    end
  end
end
