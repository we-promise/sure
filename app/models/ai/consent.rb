# Who has agreed to what. Chat and bills need the user's own AI switch, `users.ai_enabled`, and
# nothing else needs any consent.
module Ai::Consent
  USER_SWITCH = %i[chat bill_setup].freeze

  # @return [Symbol, nil] the reason the feature is denied, or nil when it's allowed
  def self.denial(feature, family:, user:)
    return :user_disabled if USER_SWITCH.include?(Ai::Routes.consent_key(feature)) && !user&.ai_enabled

    nil
  end
end
