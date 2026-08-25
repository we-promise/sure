class Settings::SecuritiesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.security"), nil ]
    ]
    @oidc_identities = Current.user.oidc_identities.order(:provider)
    @webauthn_credentials = Current.user.webauthn_credentials.order(created_at: :asc)
    @encryption_unconfigured = Rails.application.config.app_mode.self_hosted? &&
      !ActiveRecordEncryptionConfig.explicitly_configured?
  end
end
