require "test_helper"

class OauthMetadataControllerTest < ActionDispatch::IntegrationTest
  setup do
    @base = ENV["APP_URL"].presence&.chomp("/") || "http://www.example.com"
  end

  test "protected_resource returns RFC 9728 metadata" do
    get "/.well-known/oauth-protected-resource"

    assert_response :ok
    assert_equal "application/json", response.content_type.split(";").first
    json = JSON.parse(response.body)
    # /mcp, not the app origin, is the actual protected resource — it is the
    # one endpoint behind Bearer auth.
    assert_equal "#{@base}/mcp", json["resource"]
    assert_equal [ @base ], json["authorization_servers"]
    assert_equal [ "read", "read_write" ], json["scopes_supported"]
  end

  test "protected_resource is also served at the resource-scoped well-known path" do
    get "/.well-known/oauth-protected-resource/mcp"

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal "#{@base}/mcp", json["resource"]
    assert_equal [ @base ], json["authorization_servers"]
    assert_equal [ "read", "read_write" ], json["scopes_supported"]
  end

  test "authorization_server returns RFC 8414 metadata" do
    get "/.well-known/oauth-authorization-server"

    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal @base, json["issuer"]
    assert_equal "#{@base}/oauth/authorize", json["authorization_endpoint"]
    assert_equal "#{@base}/oauth/token", json["token_endpoint"]
    assert_equal "#{@base}/register", json["registration_endpoint"]
    assert_equal [ "code" ], json["response_types_supported"]
    assert_equal [ "authorization_code" ], json["grant_types_supported"]
    assert_equal [ "S256" ], json["code_challenge_methods_supported"]
    assert_equal [ "read", "read_write" ], json["scopes_supported"]
  end

  test "unauthorized MCP requests point WWW-Authenticate at a working resource_metadata URL" do
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json,
         headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
    challenge = response.headers["WWW-Authenticate"]
    url = challenge[/resource_metadata="([^"]+)"/, 1]
    assert url.present?, "WWW-Authenticate must carry a resource_metadata URL"

    get url

    assert_response :ok, "resource_metadata must point at a live, valid endpoint"
    assert_equal "#{@base}/mcp", JSON.parse(response.body)["resource"]
  end
end
