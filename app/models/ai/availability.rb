# Why a feature can or can't run for a family and user (section 16). The router returns one
# with a reason when nothing may run, and Ai.availability returns an available one otherwise.
#
# Reasons in 2b: :not_configured, :capability_missing and :user_disabled. PR 7 adds
# :no_family_consent and :consent_outdated; PR 9 :endpoint_not_allowed, :key_missing,
# :cost_cap_reached and :blocked_by_admin.
Ai::Availability = Data.define(:feature, :reason) do
  def self.available(feature) = new(feature: feature.to_sym, reason: nil)

  def self.unavailable(feature, reason) = new(feature: feature.to_sym, reason:)

  def available? = reason.nil?

  def unavailable? = !available?

  # What to tell this user, worded for someone who can act on it: the instance admin is told what
  # to set up, anyone else only that it isn't available. Nil when the feature is available.
  def message_for(user)
    return if available?

    audience = user&.manages_instance_settings? ? :admin : :member
    feature_name = I18n.t("ai.consent_rows.#{Ai::Routes.row_key(feature)}")
    I18n.t("ai.availability.#{reason}.#{audience}", feature: feature_name, default: I18n.t("ai.availability.#{reason}.member", feature: feature_name))
  end
end
