module PreviewGateable
  extend ActiveSupport::Concern

  included do
    helper_method :preview_features_enabled?
  end

  def preview_features_enabled?
    Current.user&.preview_features_enabled? == true
  end

  def preview_provider_hidden?(provider_key)
    ProviderConnectionStatus.hidden_provider_keys(preview_enabled: preview_features_enabled?).include?(provider_key.to_s)
  end

  # Use as a `before_action` on controllers that gate a preview feature.
  # Redirects users without preview access to the dashboard with a flash
  # explaining the feature is opt-in. Self-served via Settings → Preferences.
  def require_preview_features!
    return if preview_features_enabled?

    redirect_to root_path, alert: I18n.t("preview.not_enabled")
  end
end
