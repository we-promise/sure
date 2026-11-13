# Redirects away from AI-chat write actions (starting a chat, sending a
# message) when the current user hasn't gone through the AI consent flow yet.
#
# Read actions (index/new/show) are intentionally left ungated at the
# controller level — they render the same consent screen inline instead, so a
# user who lands there directly (e.g. the mobile "Assistant" nav item) sees an
# explanation and an enable button rather than a redirect loop or a bare 403.
module RequiresAiConsent
  extend ActiveSupport::Concern

  private
    def redirect_unless_ai_enabled(fallback_path)
      redirect_to fallback_path unless Current.user.ai_enabled?
    end
end
