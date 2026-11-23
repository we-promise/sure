# Who has agreed to what, at the level Ai::Routes declares for each feature. A `:user` feature
# needs the person's own AI switch, `users.ai_enabled`. A `:family` feature sends the household's
# data without anyone starting it, so it needs the family's consent (Family#ai_consented?).
module Ai::Consent
  # @return [Symbol, nil] the reason the feature is denied, or nil when it's allowed
  def self.denial(feature, family:, user:)
    case Ai::Routes.fetch(feature)[:consent]
    when :user then :user_disabled unless user&.ai_enabled
    when :family then :no_family_consent unless family&.ai_consented?
    end
  end
end
