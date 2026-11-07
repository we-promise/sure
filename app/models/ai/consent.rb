# Who has agreed to what (section 6). Until PR 7 this keeps today's checks (call by
# @josh-sanders during development of PR #4440): chat and bills need the user's own AI switch,
# `users.ai_enabled`, and nothing else needs any consent. PR 7 replaces USER_SWITCH with
# the route spec's `consent: :user` and adds the family's consent per feature; PR 9 adds the member
# switch a family admin sets.
module Ai::Consent
  USER_SWITCH = %i[chat bill_setup].freeze

  # @return [Symbol, nil] the reason the feature is denied, or nil when it's allowed
  def self.denial(feature, family:, user:)
    return :user_disabled if USER_SWITCH.include?(Ai::Routes.consent_key(feature)) && !user&.ai_enabled

    nil
  end
end
