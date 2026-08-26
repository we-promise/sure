class Settings::SecuritiesController < ApplicationController
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.security"), nil ]
    ]
    @oidc_identities = Current.user.oidc_identities.order(:provider)
    @webauthn_credentials = Current.user.webauthn_credentials.order(created_at: :asc)
    self_hosted = Rails.application.config.app_mode.self_hosted?
    @encryption_unconfigured = self_hosted && !ActiveRecordEncryptionConfig.ready?
    @encryption_using_compromised_secret = self_hosted && !@encryption_unconfigured &&
      ActiveRecordEncryptionConfig.using_known_compromised_secret_key_base?
  end
end
