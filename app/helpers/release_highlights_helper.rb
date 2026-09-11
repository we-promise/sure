module ReleaseHighlightsHelper
  # Tag of the deployed release whose highlight the user has not seen yet,
  # or nil when the popup should not render. Purely local state (no GitHub
  # call - the notes themselves are fetched lazily by the Stimulus
  # controller), so it is safe to run on every page render.
  def pending_release_tag
    return @pending_release_tag if defined?(@pending_release_tag)

    @pending_release_tag = ReleaseHighlights.pending_tag_for(Current.user)
    @pending_release_tag
  end

  # Anchored feature highlight (e.g. Bills) pending for this account, or
  # nil. Rendered on the dashboard only; purely local state, so safe to run
  # on every dashboard render.
  def pending_feature_highlight
    return @pending_feature_highlight if defined?(@pending_feature_highlight)

    @pending_feature_highlight = FeatureHighlights.pending_for(Current.user)
    @pending_feature_highlight
  end
end
