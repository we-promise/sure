module BetaGateable
  extend ActiveSupport::Concern

  included do
    helper_method :beta_features_enabled?
  end

  def beta_features_enabled?
    Current.user&.beta_features_enabled? == true
  end

  # Use as a `before_action` on controllers that gate a beta feature.
  # Redirects non-beta users to the dashboard with a flash explaining the
  # feature is opt-in. Self-served via Settings → Preferences.
  def require_beta_features!
    return if beta_features_enabled?

    redirect_to root_path, alert: I18n.t("beta.not_enabled")
  end
end
