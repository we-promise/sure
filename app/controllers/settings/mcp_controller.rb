class Settings::McpController < ApplicationController
  include OauthBase
  layout "settings"

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.mcp"), nil ]
    ]
    @mcp_url = "#{configured_base_url}/mcp"
    @connected_tokens = Doorkeeper::AccessToken
      .where(resource_owner_id: Current.user.id, revoked_at: nil)
      .where.not(id: MobileDevice.oauth_access_tokens.select(:id))
      .includes(:application)
      .order(created_at: :desc)
      .to_a
  end

  def revoke
    token = Doorkeeper::AccessToken.find_by( # pipelock:ignore
      id: params[:token_id],
      resource_owner_id: Current.user.id
    )
    token&.revoke
    redirect_to settings_mcp_path, notice: t(".revoked")
  end
end
