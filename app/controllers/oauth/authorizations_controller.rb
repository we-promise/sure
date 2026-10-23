class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController
  before_action :default_mcp_scope, only: [ :new, :create ]

  private

    def default_mcp_scope
      return if params[:scope].present?

      application = Doorkeeper::Application.find_by(uid: params[:client_id])
      # Migrated MCP registrations use mcp; honor remaining legacy applications too.
      scopes = application&.scopes.to_s.split
      params[:scope] = scopes.first if scopes == [ "mcp" ] || scopes == [ "read_write" ]
    end
end
