# Shared guards for the Bills / recurring-transactions surfaces: every
# controller in the subsystem bails to the home page when the user hasn't
# opted into preview features or the family has switched the feature off,
# and the dialog surfaces drop the layout for turbo-frame requests so the
# shared modal frame stays unique in the response.
module RecurringFeatureGuardable
  extend ActiveSupport::Concern

  private
    # Bills ships as a preview feature, so the per-user gate runs first and
    # carries the flash that points at Settings -> Preferences. The family's
    # recurring toggle still applies to opted-in users.
    def ensure_recurring_enabled
      require_preview_features!
      return if performed?

      redirect_to root_path if Current.family.recurring_transactions_disabled?
    end

    def dialog_layout
      turbo_frame_request? ? false : "settings"
    end

    # Turbo-stream redirects take a raw URL, so the referer has to be validated
    # the way redirect_back_or_to already validates it for HTML: same host, or
    # the caller's fallback.
    def safe_return_path(fallback:)
      referer = request.referer
      return fallback if referer.blank?

      uri = URI.parse(referer)
      uri.host.nil? || uri.host == request.host ? referer : fallback
    rescue URI::InvalidURIError
      fallback
    end
end
