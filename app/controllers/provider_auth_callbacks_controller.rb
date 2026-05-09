# Unified callback for all provider auth flows.
# Handles GET /provider_connections/:provider_key/auth — the single URL
# every provider registers in their upstream developer dashboard.
#
# Dispatches on adapter.auth_class:
#   OAuth2       → token exchange (code + state params from provider)
#   EmbeddedLink → re-render Link view with is_resume: true so the Plaid/MX
#                  JS controller sets receivedRedirectUri = window.location.href
class ProviderAuthCallbacksController < ApplicationController
  include ProviderAuthFlowSession

  before_action :require_admin!
  before_action :resolve_adapter!

  def show
    if @adapter.auth_class == Provider::Auth::OAuth2
      handle_oauth2_callback
    elsif @adapter.auth_class == Provider::Auth::EmbeddedLink
      handle_embedded_link_oauth_return
    else
      head :not_found
    end
  end

  private

    def provider_key
      params[:provider_key].to_s
    end

    def resolve_adapter!
      @adapter = Provider::ConnectionRegistry.adapter_for(provider_key)
    rescue NotImplementedError
      head :not_found
    end

    def handle_oauth2_callback
      flow = consume_flow(params[:state])
      unless flow
        Rails.logger.warn("[ProviderAuthCallbacksController] state mismatch or expired for provider=#{provider_key} family=#{Current.family&.id}")
        redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
        return
      end

      if flow["kind"] == "reauth"
        @connection = Current.family.provider_connections.find(flow["connection_id"])
        @connection.auth.exchange_code(code: params[:code])
        @connection.update!(status: :healthy, sync_error: nil)
        redirect_to provider_connection_path(@connection), notice: t("provider.connections.connected")
        return
      end

      config = Current.family.provider_family_configs.find(flow["provider_family_config_id"])

      @connection = Provider::Connection.transaction do
        conn = Current.family.provider_connections.create!(
          provider_key:           flow["provider_key"],
          provider_family_config: config,
          auth_type:              "oauth2",
          status:                 :healthy,
          credentials:            {},
          metadata: {
            "psu_ip"       => flow["psu_ip"],
            "redirect_uri" => flow["redirect_uri"],
            "sandbox"      => flow["sandbox"]
          }.compact
        )
        conn.auth.exchange_code(code: params[:code])
        conn
      end

      begin
        @connection.discover_accounts!
      rescue => e
        Rails.logger.warn("[ProviderAuthCallbacksController] discover_accounts! failed for connection=#{@connection.id}: #{e.class}: #{e.message}")
      end

      redirect_to setup_provider_connection_path(@connection), notice: t("provider.connections.connected")
    rescue Provider::Auth::TransientError,
           Provider::Auth::ConsentExpiredError,
           Provider::Auth::ReauthRequiredError,
           Provider::Error,
           ActiveRecord::RecordNotFound => e
      Rails.logger.warn("[ProviderAuthCallbacksController] OAuth2 callback failed: #{e.class}: #{e.message}")
      redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
    end

    def handle_embedded_link_oauth_return
      flow_id = peek_active_link_flow(provider_key)
      flow    = peek_flow(flow_id)

      unless flow
        Rails.logger.warn("[ProviderAuthCallbacksController] no active EmbeddedLink flow for provider=#{provider_key} family=#{Current.family&.id}")
        redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
        return
      end

      # Flow confirmed valid — refresh the active-link pointer so it survives
      # the re-render and remains findable until POST finish.
      consume_active_link_flow!(provider_key)
      write_active_link_flow!(provider_key, flow_id)

      urls = {
        complete:           finish_provider_link_path(provider_key: provider_key, flow_id: flow_id),
        sync:               (flow["connection_id"] ? sync_provider_connection_path(flow["connection_id"]) : nil),
        post_sync_redirect: accounts_path
      }
      @js_data = @adapter.js_data_for(flow: flow, is_resume: true, urls: urls)
      render template: "embedded_link_callbacks/new"
    end
end
