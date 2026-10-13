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
      last_seen = user.last_seen_release_tag
      return tag if last_seen.blank?
      return nil if tag == last_seen

      # Compare parsed versions, not just tag equality: during a rolling
      # deploy/rollback a user's browser can already have marked a release
      # newer than what this particular app instance is currently running
      # (User#mark_release_seen! refuses to regress the marker once that
      # happens). Offering the older popup in that case would show it again
      # on every navigation until an even newer release ships, since the
      # marker can never go back down to match it. A malformed stored tag
      # falls through to the outer rescue and still offers the highlight.
      tag if version > Semver.from_release_tag(last_seen)
    rescue ArgumentError
      # Unparseable local version (e.g. "n/a: <sha>") - nothing to highlight.
      nil
    end
  end
end
