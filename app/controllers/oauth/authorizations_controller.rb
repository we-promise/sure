class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController
  before_action :default_mcp_scope, only: [ :new, :create ]

  private

    def default_mcp_scope
      return if params[:scope].present?

      application = Doorkeeper::Application.find_by(uid: params[:client_id])
      params[:scope] = "mcp" if application&.scopes.to_s.split == [ "mcp" ]
    end
end
