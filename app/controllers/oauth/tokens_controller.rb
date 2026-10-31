class Oauth::TokensController < Doorkeeper::TokensController
  before_action :preserve_legacy_mcp_refresh_scope, only: :create

  private

    def preserve_legacy_mcp_refresh_scope
      return unless params[:grant_type] == "refresh_token" && params[:refresh_token].present?
      return if params[:scope].present? || params[:scopes].present?

      token = Doorkeeper::AccessToken.by_refresh_token(params[:refresh_token])
      return if token.nil? || token.revoked?

      application = token.application
      return unless application && !application.confidential? && application.scopes.to_s == "mcp:read_write"
      return unless token.scopes.to_s == "read_write"

      # Doorkeeper otherwise intersects the old token scope with the migrated
      # application's mcp:read_write scope and issues an empty scope. Its normal
      # client, token ownership and scope validation still apply to this request.
      request.parameters["scope"] = "read_write"
    end
end
