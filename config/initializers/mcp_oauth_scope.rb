# Cursor (and other MCP clients) often request scopes Sure does not
# advertise (`openid`, empty, etc.). Doorkeeper then renders
# "The requested scope is invalid, unknown, or malformed." Map those
# requests onto the application's own scopes before pre_auth runs.
module McpOauthScope
  extend ActiveSupport::Concern

  included do
    prepend_before_action :normalize_mcp_oauth_scope, only: [ :new, :create ]
  end

  private
    def normalize_mcp_oauth_scope
      app = Doorkeeper::Application.by_uid(params[:client_id].to_s)
      return unless app

      app_scopes = app.scopes.all.map(&:to_s)
      configured = Doorkeeper.configuration.scopes.all.map(&:to_s)
      requested = params[:scope].to_s.split
      fallback = app_scopes.include?("read_write") ? "read_write" : app_scopes.first
      return if fallback.blank?

      unknown = requested.any? { |scope| configured.exclude?(scope) }
      empty = requested.empty?
      not_on_app = requested.any? { |scope| app_scopes.exclude?(scope) }

      params[:scope] = fallback if empty || unknown || not_on_app
    end
end

Rails.application.config.to_prepare do
  unless Doorkeeper::AuthorizationsController.included_modules.include?(McpOauthScope)
    Doorkeeper::AuthorizationsController.include(McpOauthScope)
  end
end
