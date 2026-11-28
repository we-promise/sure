# Shows an unread dot on synced/imported transactions a user has not seen yet
# and marks them read as soon as a list page renders them. The dot stays on the
# rows of this render; the next render of the same rows has none.
module UnreadEntriesTrackable
  extend ActiveSupport::Concern

  private
    # Remembers when the list was loaded. "Mark all as read" on the rendered
    # page sends it back so a transaction synced after this moment, which the
    # user never saw, stays unread. Run before the entries are queried.
    def note_unread_as_of
      @unread_as_of = Time.current
    end

    # Sets @unread_entry_ids, which EntriesHelper#unread_entry? reads while the
    # rows render.
    def track_unread_entries(entries)
      entry_ids = entries.map(&:id)
      @unread_entry_ids = entry_ids.any? ? Current.user.unread_entries.where(id: entry_ids).pluck(:id).to_set : Set.new

      # Turbo hover-prefetches links and, if the user then clicks, shows that
      # prefetched response. It was not seen when it was fetched, so instead of
      # marking here the page marks its rows itself once it is displayed
      # (EntriesHelper#unread_marker_tag).
      if prefetch_request?
        @unread_entry_ids_to_mark_on_display = @unread_entry_ids
      else
        Current.user.mark_entries_read!(@unread_entry_ids)
      end
    end

    # Turbo sends X-Sec-Purpose (the fetch spec forbids setting Sec-Purpose
    # from JS) on hover-prefetch requests.
    def prefetch_request?
      request.headers["X-Sec-Purpose"] == "prefetch" || request.headers["Sec-Purpose"].to_s.include?("prefetch")
    end
end
