# Rollout policy for the "What's new" release highlight popup.
#
# The popup is keyed to the exact deployed release tag (Sure.version), so it
# can never show or mark notes for a release the user is not actually running.
module ReleaseHighlights
  class << self
    # Which releases are worth highlighting.
    #
    # While the feature is being tested, every release - including alpha
    # prereleases - triggers the highlight. Once testing settles, switch this
    # predicate to stable-only (`!version.prerelease?`); nothing else needs
    # to change.
    def eligible?(version)
      true
    end

    # Tag of the deployed release the user has not seen yet, or nil when the
    # highlight should not be offered.
    def pending_tag_for(user)
      return unless user

      version = Sure.version
      return unless eligible?(version)

      tag = version.to_release_tag
      tag unless tag == user.last_seen_release_tag
    rescue ArgumentError
      # Unparseable local version (e.g. "n/a: <sha>") - nothing to highlight.
      nil
    end
  end
end
