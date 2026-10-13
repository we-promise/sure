class Family::SyncCompleteEvent
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def broadcast
    # Replace the #sync-toast slot with a lightweight toast instead of a full
    # page refresh.  The sync-toast Stimulus controller handles three cases:
    #   - User is idle         → morph-refreshes after a short delay
    #   - User is mid-form     → toast stays visible; user clicks "Refresh"
    #   - A modal is open      → toast defers until the dialog closes
    #
    # This avoids wiping in-progress form state when a background sync fires.
    # The partial contains no user-scoped data (Current.user is nil here), so
    # each browser re-fetches the page on its own authenticated request.
    #
    # Syncing several connections (or "Sync all") finishes one sync after
    # another, and every one of them lands here. Each schedules the toast job;
    # only the newest one sends it, once no other sync is visibly running, so
    # the page refreshes once instead of once per sync. Account rows are
    # already replaced in place as each sync completes.
    schedule_sync_toast

    # The accounts page's own sync toolbar (refresh icon + "Cancel sync") is
    # plain server-rendered HTML from whatever request last loaded the page,
    # so without this it stays stuck showing "still syncing" — disabled icon,
    # "Cancel sync" visible — indefinitely after the sync actually finishes,
    # even while the toast above says otherwise. Replace it in the same
    # broadcast so the two agree. Visitors not on the accounts page simply
    # don't have #accounts-sync-controls in their DOM, so this no-ops for
    # them, same as the sync-toast replace above.
    family.broadcast_replace_to(
      family,
      target: "accounts-sync-controls",
      partial: "accounts/sync_controls",
      locals: { family: family }
    )

    # Schedule recurring transaction pattern identification (debounced to run after all syncs complete)
    begin
      RecurringTransaction.identify_patterns_for(family)
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent recurring transaction identification failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end
  end

  private
    # Scheduled after commit: this runs inside the finalizing sync's locked
    # transaction, and a rolled-back sync must not leave a toast job behind.
    def schedule_sync_toast
      ActiveRecord.after_all_transactions_commit do
        FamilySyncToastJob.schedule_for(family)
      rescue => e
        Rails.logger.error("Family::SyncCompleteEvent sync toast scheduling failed: #{e.message}")
      end
    end
end
