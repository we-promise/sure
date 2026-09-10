module ReleaseHighlightsHelper
  # Tag of the deployed release whose highlight the user has not seen yet,
  # or nil when the popup should not render. Purely local state (no GitHub
  # call - the notes themselves are fetched lazily by the Stimulus
  # controller), so it is safe to run on every page render. The changelog
  # page already shows the same notes, so the popup is suppressed there.
  def pending_release_tag
    return @pending_release_tag if defined?(@pending_release_tag)

    @pending_release_tag = ReleaseHighlights.pending_tag_for(Current.user)
    @pending_release_tag = nil if @pending_release_tag && controller_name == "pages" && action_name == "changelog"
    @pending_release_tag
  end
end
