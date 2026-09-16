class ProviderConnectionsController < ApplicationController
  layout "settings"

  before_action :require_admin!
  before_action :set_connection

  rescue_from ProviderConnection::Configuration::Conflict, Provider::AccountData::UnsupportedCapability, with: :configuration_conflict
  rescue_from Provider::AccountData::CredentialStore::Busy, with: :configuration_busy
  rescue_from ActiveRecord::RecordInvalid, ArgumentError, with: :configuration_invalid

  def edit
    @form = configuration.form
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.bank_sync"), settings_providers_path ], [ t(".title"), nil ] ]
  end

  def update
    values = params.require(:provider_connection)
    configuration.update!(token: values[:form_token],
      attributes: values.permit(:name, :sync_start_date, :access_token, :token).to_h)
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  private
    def set_connection
      @connection = Current.family.provider_connections.find(params[:id])
    end

    def configuration
      @configuration ||= ProviderConnection::Configuration.new(connection: @connection, actor: Current.user)
    end

    # Validation errors may contain supplied credentials. Keep both responses
    # and flash messages independent of exception text and submitted values.
    def configuration_conflict(error)
      configuration_failure(error, "conflict")
    end

    def configuration_busy(error)
      configuration_failure(error, "busy")
    end

    def configuration_invalid(error)
      configuration_failure(error, "invalid")
    end

    def configuration_failure(error, reason)
      capture_configuration_failure(error)
      redirect_to settings_providers_path, alert: t("provider_connections.errors.#{reason}"), status: :see_other
    end

    def capture_configuration_failure(error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Provider connection configuration was refused",
        source: self.class.name, provider_key: @connection&.provider_key, family: Current.family,
        metadata: { provider_connection_id: @connection&.id, error_class: error.class.name })
    rescue StandardError
      # Diagnostic storage must not replace the sanitized management response.
      nil
    end
end
