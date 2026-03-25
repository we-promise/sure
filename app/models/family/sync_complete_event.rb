class Family::SyncCompleteEvent
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def broadcast
    # Broadcast a refresh signal instead of rendered HTML. Each user's browser
    # re-fetches via their own authenticated request, so the balance sheet and
    # net worth chart are correctly scoped to the current user (Current.user is
    # nil in background jobs, which would produce an unscoped family-wide view).
    family.broadcast_refresh

    # Schedule recurring transaction pattern identification (debounced to run after all syncs complete)
    begin
      RecurringTransaction.identify_patterns_for(family)
    rescue => e
      Rails.logger.error("Family::SyncCompleteEvent recurring transaction identification failed: #{e.message}\n#{e.backtrace&.join("\n")}")
    end
  end
end
