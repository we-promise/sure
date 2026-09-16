# Only member URLs with an explicit legacy UUID enter this compatibility path.
# Reviewed controllers may also redirect management of live native-owned rows;
# collection pickers retain their own selection and authorization contracts.
module RetiredProviderRouting
  extend ActiveSupport::Concern

  included do
    class_attribute :retired_provider_key
    class_attribute :route_live_provider_management, default: false
    before_action :route_retired_provider, only: %i[edit update destroy sync setup_accounts complete_account_setup]
  end

  private
    def route_retired_provider
      require_admin!
      return if performed?

      options = { sync: action_name == "sync" }
      options[:include_live] = true if route_live_provider_management && !options[:sync]
      result = ProviderConnection::LegacyRoute.new(provider_key: retired_provider_key, legacy_id: params[:id],
        family: Current.family, actor: Current.user).call(**options)
      return unless result

      if action_name == "sync"
        respond_to do |format|
          format.html { redirect_to accounts_path, status: :see_other }
          format.json { head :ok }
          format.turbo_stream { head :ok }
        end
      else
        destination = if %w[setup_accounts complete_account_setup].include?(action_name)
          provider_connection_account_setup_path(result.connection)
        else
          edit_provider_connection_path(result.connection)
        end
        respond_to do |format|
          format.html { redirect_to destination, notice: t("provider_connections.legacy_route.moved"), status: :see_other }
          format.turbo_stream { redirect_to destination, notice: t("provider_connections.legacy_route.moved"), status: :see_other }
          format.json { render json: { error: "connection_moved", location: destination }, status: :conflict }
        end
      end
    rescue ProviderConnection::Management::Busy, Provider::AccountData::RetiredOwner::Busy => error
      retired_provider_failure(error, "busy")
    rescue ProviderConnection::Management::Conflict, Provider::AccountData::RetiredOwner::Conflict,
        Provider::AccountData::UnsupportedCapability => error
      retired_provider_failure(error, "conflict")
    end

    def retired_provider_failure(error, reason)
      capture_retired_provider_failure(error)
      respond_to do |format|
        format.html { redirect_to settings_providers_path, alert: t("provider_connections.errors.#{reason}"), status: :see_other }
        format.turbo_stream { redirect_to settings_providers_path, alert: t("provider_connections.errors.#{reason}"), status: :see_other }
        format.json { render json: { error: reason }, status: :conflict }
      end
    end

    def capture_retired_provider_failure(error)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn", message: "Retired provider route was refused",
        source: self.class.name, provider_key: retired_provider_key, family: Current.family,
        metadata: { error_class: error.class.name })
    rescue StandardError
      nil
    end
end
