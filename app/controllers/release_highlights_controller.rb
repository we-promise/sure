class ReleaseHighlightsController < ApplicationController
  # The "What's new" popup content: release notes for the deployed release
  # the current account has not seen yet. Fetched lazily on the user's first
  # interaction so ordinary page renders never hit the GitHub API.
  def show
    tag = ReleaseHighlights.pending_tag_for(Current.user)
    @release_notes = tag && Provider::Registry.get_provider(:github)&.fetch_release_notes(tag)

    if @release_notes
      render :show, layout: false
    else
      head :no_content
    end
  end

  # Marks the release's highlight as seen for the current account. The tag
  # is bound server-side to the release actually pending, so a client cannot
  # preemptively suppress a future release's popup by posting its tag.
  def dismiss
    tag = ReleaseHighlights.pending_tag_for(Current.user)
    return head :no_content unless tag

    # The client submits the tag it actually displayed; a rolling deploy in
    # between must not let a dismissal of the old popup mark the new release
    # seen. Mismatch: leave it pending so the new popup still shows.
    return head :conflict if params[:tag].present? && params[:tag] != tag

    Current.user.mark_release_seen!(tag)

    head :ok
  end

  # Marks a feature highlight (e.g. the anchored Bills popover) as seen.
  # Bound to the feature currently pending for this account - a client
  # cannot mark arbitrary or future features seen.
  def dismiss_feature
    pending = FeatureHighlights.pending_for(Current.user)

    if pending && pending.key == params[:key]
      Current.user.mark_feature_highlight_seen!(pending.key, pending.min_tag)

      head :ok
    else
      head :unprocessable_entity
    end
  end
end
