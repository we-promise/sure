require "test_helper"

class Oauth::TokensControllerTest < ActionDispatch::IntegrationTest
  setup do
    @oauth_application = Doorkeeper::Application.create!(
      name: "Migrated MCP Client",
      redirect_uri: "https://claude.ai/callback",
      confidential: false,
      scopes: "mcp"
    )
    @token = create_token(scopes: "read_write")
  end

  test "expired access tokens retain their scope when refreshed after application migration" do
    @token.update!(created_at: 2.years.ago)
    assert @token.expired?

    refresh

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "read_write", body["scope"]
    refreshed = Doorkeeper::AccessToken.by_token(body.fetch("access_token"))
    assert refreshed.accessible?
    assert_equal @oauth_application.id, refreshed.application_id
    assert_equal @token.resource_owner_id, refreshed.resource_owner_id
  end

  test "does not override an explicitly requested scope" do
    assert_no_difference "Doorkeeper::AccessToken.count" do
      refresh(scope: "mcp")
    end

    assert_response :bad_request
    assert_equal "invalid_scope", JSON.parse(response.body)["error"]
  end

  test "does not override an explicitly requested scopes alias" do
    assert_no_difference "Doorkeeper::AccessToken.count" do
      refresh(scopes: "mcp")
    end

    assert_response :bad_request
    assert_equal "invalid_scope", JSON.parse(response.body)["error"]
  end

  test "rejects refresh credentials belonging to a different client" do
    other_app = Doorkeeper::Application.create!(
      name: "Other MCP Client",
      redirect_uri: "https://other.example/callback",
      confidential: false,
      scopes: "mcp"
    )

    assert_no_difference "Doorkeeper::AccessToken.count" do
      refresh(client_id: other_app.uid)
    end

    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body)["error"]
  end

  test "rejects revoked refresh credentials" do
    @token.revoke

    assert_no_difference "Doorkeeper::AccessToken.count" do
      refresh
    end

    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body)["error"]
  end

  test "rejects unknown refresh credentials" do
    assert_no_difference "Doorkeeper::AccessToken.count" do
      refresh(refresh_token: SecureRandom.hex(32))
    end

    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body)["error"]
  end

  test "MCP-only tokens keep their scope on refresh" do
    token = create_token(scopes: "mcp")

    refresh(refresh_token: token.plaintext_refresh_token)

    assert_response :ok
    assert_equal "mcp", JSON.parse(response.body)["scope"]
  end

  private

    def create_token(scopes:)
      Doorkeeper::AccessToken.create!( # pipelock:ignore
        application: @oauth_application,
        resource_owner_id: users(:family_admin).id,
        scopes: scopes,
        expires_in: 1.year,
        use_refresh_token: true
      )
    end

    def refresh(overrides = {})
      post "/oauth/token", params: {
        grant_type: "refresh_token",
        client_id: @oauth_application.uid,
        refresh_token: @token.plaintext_refresh_token
      }.merge(overrides)
    end
end
