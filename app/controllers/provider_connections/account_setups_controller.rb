class ProviderConnections::AccountSetupsController < ApplicationController
  layout "settings"

  before_action :require_admin!
  before_action :set_connection

  rescue_from ProviderConnection::AccountSetup::Conflict, Provider::AccountData::UnsupportedCapability, with: :setup_conflict
  rescue_from ProviderConnection::AccountSetup::Busy, with: :setup_busy
  rescue_from ActiveRecord::RecordInvalid, ActionController::ParameterMissing, ArgumentError, with: :setup_invalid

  def show
    external_id = scalar_param(params[:external_account_id])
    account_id = scalar_param(params[:account_id])
    after = scalar_param(params[:after])
    if external_id.present?
      @form = account_setup.form(external_account_id: external_id, account_id: account_id)
      @account_type_options = @form.account_types.map { |type| [ t("accounts.types.#{type.underscore}"), type ] }
    else
      @catalog = account_setup.catalog(after: after)
    end
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.bank_sync"), settings_providers_path ],
      [ t("provider_connections.account_setup.title"), nil ] ]
  end

  def create
    values = params.require(:account_setup)
    raise ArgumentError unless values.is_a?(ActionController::Parameters)

    token = scalar_param(values[:token])
    account_setup.apply!(token: token,
      attributes: values.permit(:name, :accountable_type, :currency, :balance).to_h)
    redirect_to provider_connection_account_setup_path(@connection),
      notice: t("provider_connections.account_setup.success"), status: :see_other
  end

  def refresh
    account_setup.refresh!
    redirect_to provider_connection_account_setup_path(@connection),
      notice: t("provider_connections.account_setup.refresh_success"), status: :see_other
  end

  private
    def set_connection
      @connection = Current.family.provider_connections.find(params[:provider_connection_id])
    end

    def account_setup
      @account_setup ||= ProviderConnection::AccountSetup.new(connection: @connection, actor: Current.user)
    end

    def scalar_param(value)
      raise ArgumentError unless value.nil? || value.is_a?(String)

      value.presence
    end

    def setup_conflict(error)
      setup_failure(error, "conflict")
    end

    def setup_busy(error)
      setup_failure(error, "busy")
    end

    def setup_invalid(error)
      setup_failure(error, "invalid")
    end

    def setup_failure(error, reason)
      capture_setup_failure(error)
      destination = action_name == "show" ? settings_providers_path : provider_connection_account_setup_path(@connection)
      redirect_to destination, alert: t("provider_connections.account_setup.errors.#{reason}"), status: :see_other
    end

    def capture_setup_failure(error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Provider account setup was refused",
        source: self.class.name, provider_key: @connection&.provider_key, family: Current.family,
        metadata: { provider_connection_id: @connection&.id, error_class: error.class.name })
    rescue StandardError
      nil
    end
end
