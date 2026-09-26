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
    # RFC 9728 §3.3: a client fetching the root well-known path constructs it
    # from the bare-origin resource identifier, so that must be what this
    # document reports — not "/mcp" (that's the scoped endpoint's job below).
    assert_equal @base, json["resource"]
    assert_equal [ @base ], json["authorization_servers"]
    assert_equal [ "read", "read_write" ], json["scopes_supported"]
  end

  test "protected_resource is also served at the resource-scoped well-known path" do
    get "/.well-known/oauth-protected-resource/mcp"

    assert_response :ok
    json = JSON.parse(response.body)
    # This path is constructed from the "<base>/mcp" resource identifier, so
    # its own "resource" must match — the root document above intentionally
    # reports a different value.
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

  test "unauthorized MCP requests point WWW-Authenticate at a working, consistent resource_metadata URL" do
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "initialize" }.to_json,
         headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
    challenge = response.headers["WWW-Authenticate"]
    url = challenge[/resource_metadata="([^"]+)"/, 1]
    assert url.present?, "WWW-Authenticate must carry a resource_metadata URL"
    # RFC 9728 §3.3: the challenge must point at the resource-SCOPED path,
    # not the root one — the root document's "resource" is the bare origin,
    # which would mismatch the "<base>/mcp" a client constructs from this
    # exact URL and reject the document outright.
    assert_equal "#{@base}/.well-known/oauth-protected-resource/mcp", url

    get url

    assert_response :ok, "resource_metadata must point at a live, valid endpoint"
    assert_equal "#{@base}/mcp", JSON.parse(response.body)["resource"],
      "the resource_metadata URL's own document must report the resource identifier that URL implies"
  end
end
