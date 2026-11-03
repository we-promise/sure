class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController
  before_action :default_mcp_scope, only: [ :new, :create ]

  private

    def default_mcp_scope
      return if params[:scope].present?

      application = Doorkeeper::Application.find_by(uid: params[:client_id])
      # Use the application's sole MCP or legacy scope when the client omits it.
      scopes = application&.scopes.to_s.split
      params[:scope] = scopes.first if scopes == [ "mcp:read_write" ] || scopes == [ "read_write" ]
    end
end
