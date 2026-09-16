class ProviderConnections::DisconnectsController < ApplicationController
  layout "settings"

  before_action :require_admin!
  before_action :set_connection

  rescue_from StandardError, with: :disconnect_failed
  rescue_from ArgumentError, ActionController::ParameterMissing, ActiveRecord::RecordInvalid, with: :disconnect_invalid
  rescue_from ProviderConnection::Disconnect::Conflict, Provider::AccountData::StaleWriter,
    Provider::AccountData::UnsupportedCapability, ActiveRecord::RecordNotFound, ActiveRecord::StaleObjectError, with: :disconnect_conflict
  rescue_from ProviderConnection::Disconnect::Busy, Provider::AccountData::IncompletePage,
    ActiveRecord::LockWaitTimeout, with: :disconnect_busy

  def show
    @form = disconnect.form
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.bank_sync"), settings_providers_path ],
      [ t("provider_connections.disconnect.title"), nil ] ]
  end

  def create
    values = params.require(:disconnect)
    raise ArgumentError unless values.is_a?(ActionController::Parameters)

    token = values[:form_token]
    raise ArgumentError unless token.is_a?(String) && token.present?

    disconnect.call(token: token)
    redirect_to settings_providers_path, notice: t("provider_connections.disconnect.success"), status: :see_other
  end

  private
    def set_connection
      @connection = Current.family.provider_connections.find(params[:provider_connection_id])
    rescue ActiveRecord::RecordNotFound
      # Family scope failures stay absent; failures inside the command use the
      # sanitized stale-form response and never reveal another family's record.
      head :not_found
    end

    def disconnect
      @disconnect ||= ProviderConnection::Disconnect.new(connection: @connection, actor: Current.user)
    end

    def disconnect_conflict(error)
      disconnect_failure(error, "conflict")
    end

    def disconnect_busy(error)
      disconnect_failure(error, "busy")
    end

    def disconnect_invalid(error)
      disconnect_failure(error, "invalid")
    end

    def disconnect_failed(error)
      disconnect_failure(error, "failed")
    end

    def disconnect_failure(error, reason)
      capture_disconnect_failure(error)
      destination = action_name == "create" && @connection ? provider_connection_disconnect_path(@connection) : settings_providers_path
      redirect_to destination, alert: t("provider_connections.disconnect.errors.#{reason}"), status: :see_other
    end

    def capture_disconnect_failure(error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Provider connection disconnect was refused",
        source: self.class.name, provider_key: @connection&.provider_key, family: Current.family,
        metadata: { provider_connection_id: @connection&.id, error_class: error.class.name })
    rescue StandardError
      nil
    end
end
