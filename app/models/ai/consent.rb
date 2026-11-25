# Who has agreed to what, at the level Ai::Routes declares for each feature. A `:user` feature
# needs the person's own AI switch, `users.ai_enabled`. A `:family` feature sends the household's
# data without anyone starting it, so it needs the family's consent (Family#ai_consented?).
#
# Uploading a PDF for import is itself the request for AI, so reading it needs no switch,
# and neither does the search copy a job makes of that upload (`embed` with no user).
module Ai::Consent
  ASKED_BY_UPLOAD = %i[extract_pdf].freeze

  # @return [Symbol, nil] the reason the feature is denied, or nil when it's allowed
  def self.denial(feature, family:, user:)
    case Ai::Routes.fetch(feature)[:consent]
    when :user then :user_disabled unless switch_on?(feature, user)
    when :family then :no_family_consent unless family&.ai_consented?
    end
  end

  def self.switch_on?(feature, user)
    return true if ASKED_BY_UPLOAD.include?(feature)
    return true if user.nil? && feature == :embed

    user&.ai_enabled
  end
  private_class_method :switch_on?
end
