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
    assert_equal "read_write", app.scopes.to_s
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

  test "rejects non-loopback http redirect uri" do
    post "/register",
      params: {
        client_name: "Claude",
        redirect_uris: [ "http://evil.example/callback" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_client_metadata", json["error"]
  end

  test "allows loopback http redirect uri" do
    post "/register",
      params: {
        client_name: "Claude",
        redirect_uris: [ "http://localhost:3456/callback" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal [ "http://localhost:3456/callback" ], json["redirect_uris"]
  end

  test "allows ipv6 loopback http redirect uri" do
    post "/register",
      params: {
        client_name: "Claude",
        redirect_uris: [ "http://[::1]:3456/callback" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal [ "http://[::1]:3456/callback" ], json["redirect_uris"]
  end

  test "allows native app custom scheme redirect uri" do
    post "/register",
      params: {
        client_name: "Cursor",
        redirect_uris: [ "cursor://anysphere.cursor-mcp/oauth/callback" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal [ "cursor://anysphere.cursor-mcp/oauth/callback" ], json["redirect_uris"]
  end

  test "allows vscode custom scheme redirect uri" do
    post "/register",
      params: {
        client_name: "VS Code",
        redirect_uris: [ "vscode://augment.vscode-augment/auth/mcp" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal [ "vscode://augment.vscode-augment/auth/mcp" ], json["redirect_uris"]
  end

  test "allows mixed native and https redirect uris from a desktop client" do
    post "/register",
      params: {
        client_name: "Cursor",
        redirect_uris: [
          "cursor://anysphere.cursor-mcp/oauth/callback",
          "http://localhost:8787/callback",
          "https://www.cursor.com/agents/mcp/oauth/callback"
        ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal [
      "cursor://anysphere.cursor-mcp/oauth/callback",
      "http://localhost:8787/callback",
      "https://www.cursor.com/agents/mcp/oauth/callback"
    ], json["redirect_uris"]
  end

  test "allows reverse-domain native redirect uri without a host" do
    post "/register",
      params: {
        client_name: "Native App",
        redirect_uris: [ "com.example.app:/oauth2redirect/example-provider" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :created
    json = JSON.parse(response.body)
    assert_equal [ "com.example.app:/oauth2redirect/example-provider" ], json["redirect_uris"]
  end

  test "rejects javascript redirect uri" do
    post "/register",
      params: {
        client_name: "Claude",
        redirect_uris: [ "javascript:alert(1)" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_client_metadata", json["error"]
  end

  test "rejects file redirect uri" do
    post "/register",
      params: {
        client_name: "Claude",
        redirect_uris: [ "file:///etc/passwd" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_client_metadata", json["error"]
  end

  test "rejects data redirect uri" do
    post "/register",
      params: {
        client_name: "Claude",
        redirect_uris: [ "data:text/html,hello" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_client_metadata", json["error"]
  end

  test "rejects redirect uri with a fragment" do
    post "/register",
      params: {
        client_name: "Claude",
        redirect_uris: [ "https://claude.ai/callback#oops" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_client_metadata", json["error"]
  end

  test "rejects scheme-only custom redirect uri" do
    post "/register",
      params: {
        client_name: "Claude",
        redirect_uris: [ "cursor://" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    json = JSON.parse(response.body)
    assert_equal "invalid_client_metadata", json["error"]
  end

  test "authorization redirects to a dynamically registered native app uri" do
    post "/register",
      params: {
        client_name: "Cursor",
        redirect_uris: [ "cursor://anysphere.cursor-mcp/oauth/callback" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :created
    app = Doorkeeper::Application.find_by!(uid: JSON.parse(response.body)["client_id"])

    sign_in(users(:family_admin))
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

    post "/oauth/authorize", params: {
      client_id: app.uid,
      redirect_uri: "cursor://anysphere.cursor-mcp/oauth/callback",
      response_type: "code",
      code_challenge: challenge,
      code_challenge_method: "S256"
    }

    assert_response :redirect
    assert response.location.start_with?("cursor://anysphere.cursor-mcp/oauth/callback")
    code = Rack::Utils.parse_query(URI.parse(response.location).query)["code"]
    assert code.present?, "Authorization response should contain a code"
  end
end
