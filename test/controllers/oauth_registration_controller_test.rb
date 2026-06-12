require "test_helper"

class OauthRegistrationControllerTest < ActionDispatch::IntegrationTest
  test "registers a public client and returns client_id" do
    post "/register",
      params: {
        client_name: "Claude",
        redirect_uris: [ "https://claude.ai/callback" ],
        grant_types: [ "authorization_code" ],
        response_types: [ "code" ],
        token_endpoint_auth_method: "none"
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :created
    json = JSON.parse(response.body)
    assert json["client_id"].present?
    assert_equal "Claude", json["client_name"]
    assert_equal [ "https://claude.ai/callback" ], json["redirect_uris"]
    assert_equal [ "authorization_code" ], json["grant_types"]
    assert_equal "none", json["token_endpoint_auth_method"]
    assert_nil json["client_secret"], "Public client must not return a secret"

    app = Doorkeeper::Application.find_by(uid: json["client_id"])
    assert app.present?, "Application should be persisted"
    assert_not app.confidential?, "Application must be non-confidential (public client)"
  end

  test "returns error for invalid JSON body" do
    post "/register",
      params: "not json",
      headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_client_metadata", json["error"]
  end

  test "returns error when redirect_uris is missing" do
    post "/register",
      params: { client_name: "Claude" }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_client_metadata", json["error"]
  end

  test "returns error when redirect_uris contains only blank values" do
    post "/register",
      params: { client_name: "Claude", redirect_uris: [ "" ] }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_client_metadata", json["error"]
  end

  test "uses fallback name when client_name is absent" do
    post "/register",
      params: {
        redirect_uris: [ "https://claude.ai/callback" ],
        token_endpoint_auth_method: "none"
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal "MCP Client", json["client_name"]
  end
end
