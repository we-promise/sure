require "test_helper"

class Settings::McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "shows MCP settings page" do
    get settings_mcp_path
    assert_response :success
  end

  test "shows connected tokens" do
    app = Doorkeeper::Application.create!(
      name: "Claude",
      redirect_uri: "https://claude.ai/callback",
      confidential: false
    )
    Doorkeeper::AccessToken.create!(
      application: app,
      resource_owner_id: @user.id,
      scopes: "read",
      expires_in: 1.year
    )

    get settings_mcp_path
    assert_response :success
    assert_select "li", text: /Claude/
  end

  test "revokes a token" do
    app = Doorkeeper::Application.create!(
      name: "Claude",
      redirect_uri: "https://claude.ai/callback",
      confidential: false
    )
    token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: app,
      resource_owner_id: @user.id,
      scopes: "read",
      expires_in: 1.year
    )

    delete revoke_token_settings_mcp_path(token_id: token.id)

    assert_redirected_to settings_mcp_path
    assert token.reload.revoked_at.present?
  end

  test "does not show mobile device tokens" do
    mobile_device = MobileDevice.create!(
      user: @user,
      device_id: "test-device-#{SecureRandom.hex(4)}",
      device_name: "Test Phone",
      device_type: "ios"
    )
    app = Doorkeeper::Application.create!(
      name: "Sure Mobile",
      redirect_uri: "sureapp://oauth/callback",
      confidential: false
    )
    Doorkeeper::AccessToken.create!(
      application: app,
      resource_owner_id: @user.id,
      mobile_device_id: mobile_device.id,
      scopes: "read",
      expires_in: 1.year
    )

    get settings_mcp_path
    assert_response :success
    assert_select "li", text: /Sure Mobile/, count: 0
  end

  test "cannot revoke another user's token" do
    other_user = users(:family_member)
    app = Doorkeeper::Application.create!(
      name: "Claude",
      redirect_uri: "https://claude.ai/callback",
      confidential: false
    )
    token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: app,
      resource_owner_id: other_user.id,
      scopes: "read",
      expires_in: 1.year
    )

    delete revoke_token_settings_mcp_path(token_id: token.id)

    assert_redirected_to settings_mcp_path
    assert_nil token.reload.revoked_at
  end

  test "non-admin member cannot view MCP settings" do
    sign_in users(:family_member)
    get settings_mcp_path
    assert_redirected_to accounts_path
    assert_equal I18n.t("shared.require_admin"), flash[:alert]
  end

  test "non-admin member cannot revoke MCP tokens" do
    member = users(:family_member)
    app = Doorkeeper::Application.create!(
      name: "Claude",
      redirect_uri: "https://claude.ai/callback",
      confidential: false
    )
    token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: app,
      resource_owner_id: member.id,
      scopes: "read",
      expires_in: 1.year
    )

    sign_in member
    delete revoke_token_settings_mcp_path(token_id: token.id)

    assert_redirected_to accounts_path
    assert_nil token.reload.revoked_at
  end
end
