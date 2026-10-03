# Rollout policy for anchored feature highlights (e.g. the "Meet Bills"
# popover spotlighting the Bills nav entry).
#
# Each feature registers the release tag that introduced it; the highlight
# is pending when the deployed release carries the feature, the account has
# not seen it yet, and the user can actually use the feature. Offering a
# revamped feature again later is a one-line min_tag bump.
module FeatureHighlights
  Pending = Data.define(:key, :min_tag)

  REGISTRY = {
    # Bills ships as a preview feature and only exists for families with
    # recurring transactions on, so both gates apply to the highlight too.
    # min_tag is the first 0.7.5 alpha rather than the final tag so the
    # highlight can be exercised while 0.7.5 is still rolling out.
    "bills" => { min_tag: "v0.7.5-alpha.1", requires_preview: true, requires_recurring: true }
  }.freeze

  class << self
    # The feature highlight to offer this user, or nil. At most one feature
    # is offered at a time: when several are pending, the first registry
    # entry wins and the rest follow on later visits.
    def pending_for(user)
      return unless user

      deployed = Sure.version

      REGISTRY.each do |key, config|
        next if config[:requires_preview] && !user.preview_features_enabled?
        next if config[:requires_recurring] && user.family&.recurring_transactions_disabled?

        min = Semver.from_release_tag(config[:min_tag])
        next if deployed < min

        seen = parse_seen_tag(user.seen_feature_highlights[key])
        next if seen && !(seen < min)

        return Pending.new(key:, min_tag: config[:min_tag])
      end

      nil
    rescue ArgumentError
      # Unparseable local version (e.g. "n/a: <sha>") - nothing to highlight.
      nil
    end

    private
      def parse_seen_tag(tag)
        Semver.from_release_tag(tag) if tag
      rescue ArgumentError
        # A previously stored malformed tag counts as unseen so the account
        # recovers instead of never being offered the highlight again.
        nil
      end
  end
end
