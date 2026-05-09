# Generic controller for EmbeddedLink-style auth flows (Plaid Link, MX Connect
# Widget, Yodlee FastLink, Akoya Connect — vendor-hosted modal in-page that
# returns an opaque public_token to JS, exchanged once server-side for a
# long-lived access_token).
#
# Routes (parameterized by provider_key, all under /auth):
#   GET  /provider_connections/:provider_key/auth/new
#   POST /provider_connections/:provider_key/auth/finish/:flow_id
#
# Provider-specific work is delegated to the adapter via the
# Provider::ConnectionAdapter EmbeddedLink contract:
#   - .start_link_flow(family:, flow_id:, params:, resume_url:, oauth_redirect_url:, webhooks_url:)
#   - .complete_link_flow(family:, flow:, params:)
#   - .js_controller_name
#   - .js_data_for(flow:, is_resume:, urls:)
#
# Cross-request flow state lives in session[:provider_flows] (see
# ProviderAuthFlowSession concern). No Provider::Connection is created until
# #create completes the exchange with valid credentials.
class EmbeddedLinkCallbacksController < ApplicationController
  include ProviderAuthFlowSession

  before_action :require_admin!
  before_action :resolve_adapter!

  def new
    flow_id = SecureRandom.hex(16)
    flow = @adapter.start_link_flow(
      family:             Current.family,
      flow_id:            flow_id,
      params:             params,
      resume_url:         new_provider_link_url(provider_key: provider_key),
      oauth_redirect_url: provider_auth_url(provider_key: provider_key, host: configured_host),
      webhooks_url:       webhooks_provider_url(provider_key: provider_key)
    )
    write_flow!(flow_id, flow)
    write_active_link_flow!(provider_key, flow_id)
    render_link_view(flow_id: flow_id, flow: flow, is_resume: false)
  rescue ArgumentError => e
    Rails.logger.warn("[EmbeddedLinkCallbacksController] #{provider_key}#new rejected: #{e.message}")
    head :bad_request
  rescue StandardError => e
    # Ask the adapter to translate the upstream error into a user-actionable
    # alert. If it can (e.g. Plaid recognises "OAuth redirect URI must be
    # configured" and tells the user the exact URL to paste), we redirect
    # back to settings/providers with a structured flash entry — rendered
    # there as a prominent inline block (not the tiny toast that flash[:alert]
    # would otherwise become — those are line-clamped at 3 lines and 320px).
    # If the adapter returns nil we re-raise so the dev-mode error page
    # surfaces the underlying bug.
    result = @adapter.humanize_link_error(e, redirect_uri: provider_auth_url(provider_key: provider_key, host: configured_host))
    raise unless result
    Rails.logger.warn("[EmbeddedLinkCallbacksController] #{provider_key}#new translated #{e.class}: #{e.message}")
    flash[:provider_setup_error] = result.merge("provider_key" => provider_key)
    redirect_to settings_providers_path
  end

  def create
    flow = consume_flow(params[:flow_id])
    consume_active_link_flow!(provider_key)
    unless flow
      Rails.logger.warn("[EmbeddedLinkCallbacksController] #{provider_key} flow expired/missing for family=#{Current.family&.id}")
      redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
      return
    end

    @connection = @adapter.complete_link_flow(family: Current.family, flow: flow, params: params)

    begin
      @connection.discover_accounts!
    rescue => e
      Rails.logger.warn("[EmbeddedLinkCallbacksController] discover_accounts! failed for connection=#{@connection.id}: #{e.class}: #{e.message}")
    end

    redirect_to setup_provider_connection_path(@connection),
                notice: t("provider.connections.connected")
  rescue Provider::Auth::TransientError,
         Provider::Auth::ConsentExpiredError,
         Provider::Auth::ReauthRequiredError,
         Provider::Error,
         ActiveRecord::RecordInvalid,
         ActiveRecord::RecordNotFound => e
    Rails.logger.warn("[EmbeddedLinkCallbacksController] #{provider_key}#create failed: #{e.class}: #{e.message}")
    redirect_to settings_providers_path, alert: t("provider.connections.connection_failed")
  end

  private

    def provider_key
      params[:provider_key].to_s
    end

    def resolve_adapter!
      @adapter = Provider::ConnectionRegistry.adapter_for(provider_key)
      unless @adapter.auth_class == Provider::Auth::EmbeddedLink
        head :not_found
      end
    rescue NotImplementedError
      head :not_found
    end

    def render_link_view(flow_id:, flow:, is_resume:)
      # Compute every URL the adapter's JS may need here — adapters MUST NOT
      # touch Rails.application.routes themselves. Keeps routing knowledge
      # in one layer.
      urls = {
        complete:           finish_provider_link_path(provider_key: provider_key, flow_id: flow_id),
        sync:               (flow["connection_id"] ? sync_provider_connection_path(flow["connection_id"]) : nil),
        post_sync_redirect: accounts_path
      }
      @js_data = @adapter.js_data_for(flow: flow, is_resume: is_resume, urls: urls)
      render :new
    end
end
