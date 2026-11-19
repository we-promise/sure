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

  # Marks the release's highlight as seen for the current account. The
  # client passes the tag it displayed; when absent we fall back to the
  # currently deployed tag.
  def dismiss
    tag = params[:tag].presence || Sure.version.to_release_tag
    Current.user.mark_release_seen!(tag)

    head :ok
  rescue ArgumentError
    head :unprocessable_entity
  end
end
