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
    family.broadcast_replace_to(
      family,
      target: "sync-toast",
      partial: "shared/notifications/sync_toast"
    )

    # Schedule recurring transaction pattern identification (debounced to run after all syncs complete)
    begin
      RecurringTransaction.identify_patterns_for(family)
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent recurring transaction identification failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end
  end
end
