# Why a feature can or can't run for a family and user. The router returns one with a reason
# when nothing may run, and Ai.availability returns an available one otherwise.
#
# Reasons: :not_configured, :capability_missing and :user_disabled.
Ai::Availability = Data.define(:feature, :reason) do
  def self.available(feature) = new(feature: feature.to_sym, reason: nil)

  def self.unavailable(feature, reason) = new(feature: feature.to_sym, reason:)

  def available? = reason.nil?

  # What to tell this user, worded for someone who can act on it: the instance admin is told what
  # to set up, anyone else only that it isn't available. Nil when the feature is available.
  def message_for(user)
    return if available?

    audience = user&.manages_instance_settings? ? :admin : :member
    feature_name = I18n.t("ai.consent_rows.#{Ai::Routes.row_key(feature)}")
    I18n.t("ai.availability.#{reason}.#{audience}", feature: feature_name, default: I18n.t("ai.availability.#{reason}.member", feature: feature_name))
  end
end
