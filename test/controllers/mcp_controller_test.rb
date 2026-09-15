require "test_helper"

class McpControllerTest < ActionDispatch::IntegrationTest
  MCP_PROTOCOL_VERSION = "2025-06-18"

  setup do
    @user = users(:family_admin)
    @token = "test-mcp-token-#{SecureRandom.hex(8)}"
  end

  # -- Authentication --

  test "returns 401 without authorization header" do
    post "/mcp", params: jsonrpc_request("initialize").to_json,
         headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
    assert_equal "unauthorized", JSON.parse(response.body)["error"]
    assert response.headers["WWW-Authenticate"].present?, "Must include WWW-Authenticate header"
    assert_includes response.headers["WWW-Authenticate"], "oauth-protected-resource"
    # RFC 6750 §3 scope hint, per the MCP authorization spec's Scope Selection
    # Strategy: tells a client the least-privilege scope to request first.
    assert_includes response.headers["WWW-Authenticate"], 'scope="read"'
  end

  test "returns 401 with wrong token" do
    post "/mcp", params: jsonrpc_request("initialize").to_json,
         headers: mcp_headers("wrong-token")

    assert_response :unauthorized
    assert response.headers["WWW-Authenticate"].present?
  end

  test "authenticates via Doorkeeper bearer token" do
    app = Doorkeeper::Application.create!(
      name: "Test MCP Client #{SecureRandom.hex(4)}",
      redirect_uri: "https://claude.ai/callback",
      confidential: false
    )
    token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: app,
      resource_owner_id: @user.id,
      scopes: "read_write",
      expires_in: 1.year
    )

    post "/mcp", params: jsonrpc_request("initialize").to_json,
         headers: mcp_headers(token.token)

    assert_response :ok
    result = JSON.parse(response.body)["result"]
    assert_mcp_initialize_response(result)
  end

  test "authenticates a token issued to a dynamically registered MCP client (default read scope)" do
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
    app = Doorkeeper::Application.find_by!(uid: JSON.parse(response.body)["client_id"])
    # Least privilege by default: a client registered without requesting a
    # scope gets "read", not the old blanket "read_write".
    assert_equal "read", app.scopes.to_s

    sign_in(@user)
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

    post "/oauth/authorize", params: {
      client_id: app.uid,
      redirect_uri: app.redirect_uri,
      response_type: "code",
      code_challenge: challenge,
      code_challenge_method: "S256"
    }

    assert_response :redirect
    code = Rack::Utils.parse_query(URI.parse(response.location).query)["code"]
    assert code.present?, "Authorization response should contain a code"

    post "/oauth/token", params: {
      grant_type: "authorization_code",
      client_id: app.uid,
      redirect_uri: app.redirect_uri,
      code: code,
      code_verifier: verifier
    }

    assert_response :success
    token_response = JSON.parse(response.body)
    assert_equal "read", token_response["scope"]

    post "/mcp", params: jsonrpc_request("initialize").to_json,
         headers: mcp_headers(token_response["access_token"])

    assert_response :ok
    assert_mcp_initialize_response(JSON.parse(response.body)["result"])
  end

  test "a dynamically registered client that explicitly requests read_write keeps full MCP access" do
    post "/register",
      params: {
        client_name: "Claude",
        redirect_uris: [ "https://claude.ai/callback" ],
        scope: "read_write"
      }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :created
    app = Doorkeeper::Application.find_by!(uid: JSON.parse(response.body)["client_id"])
    assert_equal "read_write", app.scopes.to_s

    sign_in(@user)
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

    post "/oauth/authorize", params: {
      client_id: app.uid,
      redirect_uri: app.redirect_uri,
      response_type: "code",
      code_challenge: challenge,
      code_challenge_method: "S256"
    }
    code = Rack::Utils.parse_query(URI.parse(response.location).query)["code"]

    post "/oauth/token", params: {
      grant_type: "authorization_code",
      client_id: app.uid,
      redirect_uri: app.redirect_uri,
      code: code,
      code_verifier: verifier
    }
    token_response = JSON.parse(response.body)
    assert_equal "read_write", token_response["scope"]

    post "/mcp", params: jsonrpc_request("tools/list").to_json,
         headers: mcp_headers(token_response["access_token"])

    assert_response :ok
    tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
    assert_includes tool_names, "update_transaction"
  end

  test "OAuth token with neither read nor read_write scope is rejected" do
    token = create_oauth_token(scope: "")

    post "/mcp", params: jsonrpc_request("initialize").to_json,
         headers: mcp_headers(token.token)

    assert_response :unauthorized
  end

  test "rejects expired Doorkeeper token" do
    app = Doorkeeper::Application.create!(
      name: "Test MCP Client #{SecureRandom.hex(4)}",
      redirect_uri: "https://claude.ai/callback",
      confidential: false
    )
    token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: app,
      resource_owner_id: @user.id,
      scopes: "read_write",
      expires_in: -1.second # already expired at creation time
    )

    post "/mcp", params: jsonrpc_request("initialize").to_json,
         headers: mcp_headers(token.token)

    assert_response :unauthorized
  end

  test "rejects token for deactivated user" do
    inactive_user = users(:family_member)
    inactive_user.update!(active: false)
    app = Doorkeeper::Application.create!(
      name: "Test MCP Client #{SecureRandom.hex(4)}",
      redirect_uri: "https://claude.ai/callback",
      confidential: false
    )
    token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: app,
      resource_owner_id: inactive_user.id,
      scopes: "read_write",
      expires_in: 1.year
    )

    post "/mcp", params: jsonrpc_request("initialize").to_json,
         headers: mcp_headers(token.token)

    assert_response :unauthorized
  ensure
    inactive_user&.update!(active: true)
  end

  test "env-var token still works as fallback" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("initialize").to_json,
           headers: mcp_headers(@token)

      assert_response :ok
    end
  end

  test "returns 401 and warns when env-var token matches but MCP_USER_EMAIL finds no user" do
    with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => "nonexistent@example.com") do # pipelock:ignore
      Rails.logger.expects(:warn).with(regexp_matches(/MCP_USER_EMAIL/)).once

      post "/mcp", params: jsonrpc_request("initialize").to_json,
           headers: mcp_headers(@token)

      assert_response :unauthorized
    end
  end

  # -- Read-only access mode --

  test "server/discover requires authentication" do
    post "/mcp", params: jsonrpc_request("server/discover").to_json,
         headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end

  test "server/discover rejects a wrong bearer token" do
    post "/mcp", params: jsonrpc_request("server/discover").to_json,
         headers: mcp_headers("wrong-token")

    assert_response :unauthorized
  end

  test "MCP_API_TOKEN keeps read-write behavior when MCP_READ_ONLY and MCP_API_TOKEN_SCOPE are unset" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/list").to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
      assert_includes tool_names, "update_transaction"
      assert_includes tool_names, "update_budget"
    end
  end

  WRITE_TOOL_NAMES = %w[
    import_bank_statement create_goal create_tag update_tag create_category
    update_category update_transaction update_budget upload_account_statement
    record_valuation create_bill update_bill record_bill_payment
  ].freeze

  # -- OAuth scope: read --

  test "OAuth read scope authenticates and exposes only read tools" do
    token = create_oauth_token(scope: "read")

    post "/mcp", params: jsonrpc_request("tools/list").to_json,
         headers: mcp_headers(token.token)

    assert_response :ok
    tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }

    assert_includes tool_names, "get_transactions"
    assert_includes tool_names, "get_accounts"
    assert_includes tool_names, "get_balance_sheet"
    WRITE_TOOL_NAMES.each { |name| assert_not_includes tool_names, name }
  end

  test "OAuth read scope hides write tools even for a user with preview features on" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    token = create_oauth_token(scope: "read")

    post "/mcp", params: jsonrpc_request("tools/list").to_json,
         headers: mcp_headers(token.token)

    assert_response :ok
    tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }

    WRITE_TOOL_NAMES.each { |name| assert_not_includes tool_names, name }
  end

  test "tools/call refuses a write tool by exact name for an OAuth read-scope token, identically to an unknown tool" do
    token = create_oauth_token(scope: "read")
    transaction = transactions(:one)
    original_category_id = transaction.category_id

    post "/mcp", params: jsonrpc_request("tools/call", {
      name: "update_transaction",
      arguments: { id: transaction.id, notes: "should never be written" }
    }, id: 55).to_json, headers: mcp_headers(token.token)

    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal(-32602, body["error"]["code"])
    assert_includes body["error"]["message"], "Unknown tool: update_transaction"

    post "/mcp", params: jsonrpc_request("tools/call", {
      name: "nonexistent_tool",
      arguments: {}
    }, id: 56).to_json, headers: mcp_headers(token.token)

    unknown_tool_body = JSON.parse(response.body)
    assert_equal body["error"]["message"].sub("update_transaction", "nonexistent_tool"), unknown_tool_body["error"]["message"],
      "A hidden write tool and a genuinely unknown tool must be indistinguishable"

    transaction.reload
    assert_equal original_category_id, transaction.category_id
    assert_not_equal "should never be written", transaction.entry.notes
  end

  test "tools/call executes a read tool normally for an OAuth read-scope token" do
    token = create_oauth_token(scope: "read")

    post "/mcp", params: jsonrpc_request("tools/call", {
      name: "get_balance_sheet",
      arguments: {}
    }).to_json, headers: mcp_headers(token.token)

    assert_response :ok
    result = JSON.parse(response.body)["result"]
    assert_not result["isError"]
    inner = JSON.parse(result["content"][0]["text"])
    assert inner.key?("net_worth") || inner.key?("error")
  end

  test "OAuth read_write scope keeps the full MCP surface available" do
    token = create_oauth_token(scope: "read_write")

    post "/mcp", params: jsonrpc_request("tools/list").to_json,
         headers: mcp_headers(token.token)

    assert_response :ok
    tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
    assert_includes tool_names, "update_transaction"
    assert_includes tool_names, "update_budget"
  end

  # -- MCP_API_TOKEN_SCOPE (static token, same read/read_write levels as OAuth) --

  test "MCP_API_TOKEN_SCOPE=read restricts the static token to read-only tools" do
    with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => @user.email, "MCP_API_TOKEN_SCOPE" => "read") do # pipelock:ignore
      post "/mcp", params: jsonrpc_request("tools/list").to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
      assert_includes tool_names, "get_accounts"
      WRITE_TOOL_NAMES.each { |name| assert_not_includes tool_names, name }
    end
  end

  test "MCP_API_TOKEN_SCOPE=read_write matches the historical default" do
    with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => @user.email, "MCP_API_TOKEN_SCOPE" => "read_write") do # pipelock:ignore
      post "/mcp", params: jsonrpc_request("tools/list").to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
      assert_includes tool_names, "update_transaction"
    end
  end

  test "an invalid MCP_API_TOKEN_SCOPE fails authentication instead of defaulting to read_write" do
    with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => @user.email, "MCP_API_TOKEN_SCOPE" => "admin") do # pipelock:ignore
      Rails.logger.expects(:warn).with(regexp_matches(/MCP_API_TOKEN_SCOPE/)).once

      post "/mcp", params: jsonrpc_request("initialize").to_json,
           headers: mcp_headers(@token)

      assert_response :unauthorized
    end
  end

  # -- Global kill switch --

  test "MCP_READ_ONLY=true blocks write tools even for the historical MCP_API_TOKEN" do
    with_mcp_env do
      with_env_overrides("MCP_READ_ONLY" => "true") do
        post "/mcp", params: jsonrpc_request("tools/list").to_json,
             headers: mcp_headers(@token)

        assert_response :ok
        tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
        WRITE_TOOL_NAMES.each { |name| assert_not_includes tool_names, name }

        post "/mcp", params: jsonrpc_request("tools/call", {
          name: "update_budget",
          arguments: { budgeted_spending: 1 }
        }, id: 57).to_json, headers: mcp_headers(@token)

        body = JSON.parse(response.body)
        assert_equal(-32602, body["error"]["code"])
      end
    end
  end

  test "MCP_READ_ONLY=true also restricts an OAuth read_write connection" do
    token = create_oauth_token(scope: "read_write")

    with_env_overrides("MCP_READ_ONLY" => "true") do
      post "/mcp", params: jsonrpc_request("tools/list").to_json,
           headers: mcp_headers(token.token)

      assert_response :ok
      tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
      WRITE_TOOL_NAMES.each { |name| assert_not_includes tool_names, name }
    end
  end

  # Black-box adversarial test: the full public HTTP surface only, no
  # internal helpers — registration, authorization-code + PKCE, token
  # issuance, tools/list, then a direct tools/call on a write tool's exact
  # name that tools/list never advertised. A client that already knows (or
  # guesses) a hidden tool's name must still be unable to run it, and the
  # database must show no trace of the attempt.
  test "adversarial: a client that never asked for read_write cannot reach a write tool by name" do
    with_mcp_cache do
      post "/register",
        params: {
          client_name: "Adversarial Client",
          redirect_uris: [ "https://claude.ai/callback" ]
          # No "scope" — least privilege by default gives this client "read".
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      assert_response :created
      app = Doorkeeper::Application.find_by!(uid: JSON.parse(response.body)["client_id"])
      assert_equal "read", app.scopes.to_s

      sign_in(@user)
      verifier = SecureRandom.urlsafe_base64(64)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

      post "/oauth/authorize", params: {
        client_id: app.uid,
        redirect_uri: app.redirect_uri,
        response_type: "code",
        code_challenge: challenge,
        code_challenge_method: "S256"
      }
      code = Rack::Utils.parse_query(URI.parse(response.location).query)["code"]

      post "/oauth/token", params: {
        grant_type: "authorization_code",
        client_id: app.uid,
        redirect_uri: app.redirect_uri,
        code: code,
        code_verifier: verifier
      }
      access_token = JSON.parse(response.body)["access_token"]
      assert access_token.present?

      post "/mcp", params: jsonrpc_request("initialize").to_json,
           headers: mcp_headers(access_token)
      assert_response :ok
      session_id = JSON.parse(response.body).dig("result", "sessionId")

      post "/mcp", params: jsonrpc_request("tools/list").to_json,
           headers: mcp_headers(access_token).merge("Mcp-Session-Id" => session_id)
      assert_response :ok
      advertised_tools = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
      assert_not_includes advertised_tools, "update_transaction"

      transaction = transactions(:one)
      original_category_id = transaction.category_id
      original_notes = transaction.entry.notes

      post "/mcp", params: jsonrpc_request("tools/call", {
        name: "update_transaction",
        arguments: { id: transaction.id, notes: "planted by an adversarial client" }
      }, id: 900).to_json, headers: mcp_headers(access_token).merge("Mcp-Session-Id" => session_id)

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal(-32602, body["error"]["code"])
      assert_includes body["error"]["message"], "Unknown tool: update_transaction"

      transaction.reload
      assert_equal original_category_id, transaction.category_id
      assert_equal original_notes, transaction.entry.notes
    end
  end

  # -- Session privilege preservation --

  test "a session minted with an OAuth read-scope token stays read-only even when reused with a read-write token" do
    with_mcp_cache do
      with_mcp_env do
        readonly_token = create_oauth_token(scope: "read")

        post "/mcp", params: jsonrpc_request("initialize").to_json,
             headers: mcp_headers(readonly_token.token)

        assert_response :ok
        session_id = response.headers["Mcp-Session-Id"]
        assert session_id.present?

        # Same session id, but this request authenticates with the historical
        # read-write token — the session's own access mode must still win.
        post "/mcp", params: jsonrpc_request("tools/list").to_json,
             headers: mcp_headers(@token).merge(
               "Mcp-Protocol-Version" => MCP_PROTOCOL_VERSION,
               "Mcp-Session-Id" => session_id
             )

        assert_response :ok
        tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
        WRITE_TOOL_NAMES.each { |name| assert_not_includes tool_names, name }
      end
    end
  end

  test "a session minted with an OAuth read_write token keeps write tools available on reuse" do
    with_mcp_cache do
      token = create_oauth_token(scope: "read_write")

      post "/mcp", params: jsonrpc_request("initialize").to_json,
           headers: mcp_headers(token.token)
      assert_response :ok
      session_id = response.headers["Mcp-Session-Id"]

      post "/mcp", params: jsonrpc_request("tools/list").to_json,
           headers: mcp_headers(token.token).merge(
             "Mcp-Protocol-Version" => MCP_PROTOCOL_VERSION,
             "Mcp-Session-Id" => session_id
           )

      assert_response :ok
      tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
      assert_includes tool_names, "update_transaction"
    end
  end

  test "an ambiguous access_mode in a cached session never grants more than the current credential already has" do
    with_mcp_cache do
      with_mcp_env do
        session_id = SecureRandom.uuid
        Rails.cache.write("mcp:session:#{session_id}", { user_id: @user.id, access_mode: "not_a_real_mode" }, expires_in: 1.day)
        readonly_token = create_oauth_token(scope: "read")

        post "/mcp", params: jsonrpc_request("tools/list").to_json,
             headers: mcp_headers(readonly_token.token).merge(
               "Mcp-Protocol-Version" => MCP_PROTOCOL_VERSION,
               "Mcp-Session-Id" => session_id
             )

        assert_response :ok
        tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
        WRITE_TOOL_NAMES.each { |name| assert_not_includes tool_names, name }
      end
    end
  end

  test "a legacy cache entry storing a bare user id is still accepted, at its historical read-write level" do
    with_mcp_cache do
      with_mcp_env do
        session_id = SecureRandom.uuid
        Rails.cache.write("mcp:session:#{session_id}", @user.id, expires_in: 1.day)

        post "/mcp", params: jsonrpc_request("tools/list").to_json,
             headers: mcp_headers(@token).merge(
               "Mcp-Protocol-Version" => MCP_PROTOCOL_VERSION,
               "Mcp-Session-Id" => session_id
             )

        assert_response :ok
        tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
        assert_includes tool_names, "update_transaction", "legacy sessions predate read-only tokens and were always read-write"
      end
    end
  end

  # -- JSON-RPC protocol --

  test "returns parse error for invalid JSON" do
    with_mcp_env do
      # Send with text/plain to bypass Rails JSON middleware parsing
      post "/mcp", params: "not valid json",
           headers: mcp_headers(@token).merge("Content-Type" => "text/plain")

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal(-32700, body["error"]["code"])
      assert_includes body["error"]["message"], "Parse error"
    end
  end

  test "returns invalid request for missing jsonrpc version" do
    with_mcp_env do
      post "/mcp", params: { method: "initialize" }.to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal(-32600, body["error"]["code"])
    end
  end

  test "returns method not found for unknown method with request id preserved" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("unknown/method", {}, id: 77).to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal(-32601, body["error"]["code"])
      assert_includes body["error"]["message"], "unknown/method"
      assert_equal 77, body["id"], "Error response must echo the request id"
    end
  end

  # -- Notifications (requests without id) --
  #
  # MCP Streamable HTTP: a notification (no "id") gets 202 Accepted with an
  # empty body, not 204 — the historical initialize / notifications/initialized
  # workflow still works, only the status code changed.

  test "notifications receive no response body" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_notification("notifications/initialized").to_json,
           headers: mcp_headers(@token)

      assert_response :accepted
      assert response.body.blank?, "Notification must not produce a response body"
    end
  end

  test "tools/call sent as notification does not execute" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_notification("tools/call", { name: "get_balance_sheet", arguments: {} }).to_json,
           headers: mcp_headers(@token)

      assert_response :accepted
      assert response.body.blank?, "Notification-style tools/call must not execute or respond"
    end
  end

  test "unknown notification method still returns no content" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_notification("notifications/unknown").to_json,
           headers: mcp_headers(@token)

      assert_response :accepted
      assert response.body.blank?
    end
  end

  # -- initialize --

  test "initialize returns server info and capabilities" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("initialize", { protocolVersion: MCP_PROTOCOL_VERSION }).to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      result = body["result"]

      assert_equal "2.0", body["jsonrpc"]
      assert_equal 1, body["id"]
      assert_mcp_initialize_response(result)
      assert_equal "sure", result["serverInfo"]["name"]
      assert result["capabilities"].key?("tools")
    end
  end

  test "initialize echoes a supported legacy protocol version" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("initialize", { protocolVersion: "2025-03-26" }).to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      result = JSON.parse(response.body)["result"]
      assert_equal "2025-03-26", result["protocolVersion"]
      assert_equal "2025-03-26", response.headers["Mcp-Protocol-Version"]
      assert_match(/\A[0-9a-f-]{36}\z/, result["sessionId"])
    end
  end

  test "initialize negotiates unsupported protocol versions to the default version" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("initialize", { protocolVersion: "2099-01-01" }, id: 24).to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal 24, body["id"]
      assert_equal MCP_PROTOCOL_VERSION, body.dig("result", "protocolVersion")
      assert_equal MCP_PROTOCOL_VERSION, response.headers["Mcp-Protocol-Version"]
    end
  end

  # -- 2026-07-28 (stateless/self-contained dialect) --

  MODERN_PROTOCOL_VERSION = "2026-07-28"

  test "initialize accepts the 2026-07-28 protocol version" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("initialize", { protocolVersion: MODERN_PROTOCOL_VERSION }).to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      result = JSON.parse(response.body)["result"]
      assert_equal MODERN_PROTOCOL_VERSION, result["protocolVersion"]
      assert_equal MODERN_PROTOCOL_VERSION, response.headers["Mcp-Protocol-Version"]
    end
  end

  test "server/discover returns the 2026-07-28 result shape without minting a session" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("server/discover", {
        _meta: { "io.modelcontextprotocol/protocolVersion" => MODERN_PROTOCOL_VERSION }
      }).to_json,
        headers: mcp_headers(@token).merge("Mcp-Protocol-Version" => MODERN_PROTOCOL_VERSION)

      assert_response :ok
      body = JSON.parse(response.body)
      result = body["result"]

      assert_equal "complete", result["resultType"]
      assert_includes result["supportedVersions"], MODERN_PROTOCOL_VERSION
      assert result["capabilities"].key?("tools")
      assert_equal "sure", result.dig("_meta", "io.modelcontextprotocol/serverInfo", "name")
      assert_nil result["serverInfo"], "serverInfo must live under result._meta, not directly under result"
      assert_nil response.headers["Mcp-Session-Id"], "server/discover must not create a session"
    end
  end

  test "server/discover still requires authentication" do
    post "/mcp", params: jsonrpc_request("server/discover").to_json,
         headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end

  test "tools/list adds resultType complete for the 2026-07-28 dialect" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/list").to_json,
           headers: mcp_headers(@token).merge("Mcp-Protocol-Version" => MODERN_PROTOCOL_VERSION)

      assert_response :ok
      result = JSON.parse(response.body)["result"]
      assert_equal "complete", result["resultType"]
      assert_kind_of Array, result["tools"]
      assert_equal "sure", result.dig("_meta", "io.modelcontextprotocol/serverInfo", "name")
    end
  end

  test "tools/call adds resultType complete for the 2026-07-28 dialect" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/call", { name: "get_balance_sheet", arguments: {} }).to_json,
           headers: mcp_headers(@token).merge("Mcp-Protocol-Version" => MODERN_PROTOCOL_VERSION)

      assert_response :ok
      result = JSON.parse(response.body)["result"]
      assert_equal "complete", result["resultType"]
      assert_not result["isError"]
      assert_equal "sure", result.dig("_meta", "io.modelcontextprotocol/serverInfo", "name")
    end
  end

  test "rejects a request whose header and _meta protocol versions disagree" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/list", {
        _meta: { "io.modelcontextprotocol/protocolVersion" => MCP_PROTOCOL_VERSION }
      }, id: 61).to_json,
        headers: mcp_headers(@token).merge("Mcp-Protocol-Version" => MODERN_PROTOCOL_VERSION)

      assert_response :bad_request
      body = JSON.parse(response.body)
      assert_equal 61, body["id"]
      assert_equal(-32600, body["error"]["code"])
    end
  end

  test "legacy 2025-03-26 workflow is unchanged: initialize, notifications/initialized, tools/list, tools/call" do
    with_mcp_cache do
      with_mcp_env do
        post "/mcp", params: jsonrpc_request("initialize", { protocolVersion: "2025-03-26" }).to_json,
             headers: mcp_headers(@token)
        assert_response :ok
        session_id = JSON.parse(response.body).dig("result", "sessionId")

        post "/mcp", params: jsonrpc_notification("notifications/initialized").to_json,
             headers: mcp_headers(@token).merge("Mcp-Protocol-Version" => "2025-03-26", "Mcp-Session-Id" => session_id)
        assert_response :accepted
        assert response.body.blank?

        post "/mcp", params: jsonrpc_request("tools/list").to_json,
             headers: mcp_headers(@token).merge("Mcp-Protocol-Version" => "2025-03-26", "Mcp-Session-Id" => session_id)
        assert_response :ok
        tools_result = JSON.parse(response.body)["result"]
        assert_not tools_result.key?("resultType"), "legacy dialect must not gain resultType"
        assert_kind_of Array, tools_result["tools"]

        post "/mcp", params: jsonrpc_request("tools/call", { name: "get_balance_sheet", arguments: {} }).to_json,
             headers: mcp_headers(@token).merge("Mcp-Protocol-Version" => "2025-03-26", "Mcp-Session-Id" => session_id)
        assert_response :ok
        call_result = JSON.parse(response.body)["result"]
        assert_not call_result.key?("resultType")
      end
    end
  end

  # -- tools/list --

  test "tools/list returns all assistant function tools" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/list").to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      tools = body["result"]["tools"]

      assert_kind_of Array, tools
      assert_equal Assistant.function_classes(@user).size, tools.size

      tool_names = tools.map { |t| t["name"] }
      assert_includes tool_names, "get_transactions"
      assert_includes tool_names, "get_accounts"
      assert_includes tool_names, "get_holdings"
      assert_includes tool_names, "get_balance_sheet"
      assert_includes tool_names, "get_income_statement"
      assert_includes tool_names, "update_transaction"
      assert_includes tool_names, "update_budget"

      # Each tool has required fields
      tools.each do |tool|
        assert tool["name"].present?, "Tool missing name"
        assert tool["description"].present?, "Tool #{tool['name']} missing description"
        assert tool["inputSchema"].present?, "Tool #{tool['name']} missing inputSchema"
        assert_equal "object", tool["inputSchema"]["type"]
      end
    end
  end

  test "tools/list accepts and echoes a valid MCP session id" do
    with_mcp_cache do
      with_mcp_env do
        post "/mcp", params: jsonrpc_request("initialize").to_json,
             headers: mcp_headers(@token)

        assert_response :ok
        session_id = response.headers["Mcp-Session-Id"]
        assert session_id.present?, "initialize should return an MCP session id"

        post "/mcp", params: jsonrpc_request("tools/list").to_json,
             headers: mcp_headers(@token).merge(
               "Mcp-Protocol-Version" => MCP_PROTOCOL_VERSION,
               "Mcp-Session-Id" => session_id
             )

        assert_response :ok
        assert_equal MCP_PROTOCOL_VERSION, response.headers["Mcp-Protocol-Version"]
        assert_equal session_id, response.headers["Mcp-Session-Id"]
        assert_kind_of Array, JSON.parse(response.body).dig("result", "tools")
      end
    end
  end

  test "tools/list rejects an invalid MCP session id" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/list", {}, id: 25).to_json,
           headers: mcp_headers(@token).merge(
             "Mcp-Protocol-Version" => MCP_PROTOCOL_VERSION,
             "Mcp-Session-Id" => SecureRandom.uuid
           )

      assert_response :not_found
      body = JSON.parse(response.body)
      assert_equal 25, body["id"]
      assert_equal(-32600, body["error"]["code"])
      assert_includes body["error"]["message"], "Invalid MCP session id"
    end
  end

  test "tools/list rejects unsupported MCP protocol version headers" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/list", {}, id: 26).to_json,
           headers: mcp_headers(@token).merge("Mcp-Protocol-Version" => "2099-01-01")

      assert_response :bad_request
      body = JSON.parse(response.body)
      assert_equal 26, body["id"]
      assert_equal(-32600, body["error"]["code"])
      assert_includes body["error"]["message"], "2099-01-01"
    end
  end

  test "tools/list omits preview tools for a user without preview features" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/list").to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }

      assert_includes tool_names, "get_transactions"
      Assistant::PREVIEW_FUNCTION_CLASSES.each do |fn_class|
        assert_not_includes tool_names, fn_class.name
      end
    end
  end

  test "tools/list includes preview tools for an opted-in user" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/list").to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      tool_names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }

      Assistant::PREVIEW_FUNCTION_CLASSES.each do |fn_class|
        assert_includes tool_names, fn_class.name
      end
    end
  end

  # -- tools/call --

  test "tools/call rejects a preview tool for a user without preview features" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))

    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/call", { name: "list_account_statements", arguments: {} }, id: 42).to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal(-32602, body["error"]["code"])
      assert_includes body["error"]["message"], "list_account_statements"
    end
  end

  test "tools/call returns error for unknown tool with request id preserved" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/call", { name: "nonexistent_tool", arguments: {} }, id: 99).to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal(-32602, body["error"]["code"])
      assert_includes body["error"]["message"], "nonexistent_tool"
      assert_equal 99, body["id"], "Error response must echo the request id"
    end
  end

  test "tools/call executes get_balance_sheet" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/call", {
        name: "get_balance_sheet",
        arguments: {}
      }).to_json, headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      result = body["result"]

      assert_kind_of Array, result["content"]
      assert_equal "text", result["content"][0]["type"]

      # The text field should be valid JSON
      inner = JSON.parse(result["content"][0]["text"])
      assert inner.key?("net_worth") || inner.key?("error"),
             "Expected balance sheet data or error, got: #{inner.keys}"
    end
  end

  # A vault payload is richer than the other tools' output — nested account hashes,
  # BigDecimal balances, dates, a `.compact`ed hash — so these exercise a real
  # record all the way out through tools/call's JSON envelope, rather than
  # trusting that the unit-tested return value serializes cleanly.
  test "tools/call round-trips a real vault payload through list_account_statements" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    statement = AccountStatement.create_from_upload!(
      family: @user.family,
      account: accounts(:depository),
      file: uploaded_file(filename: "statement.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )

    with_mcp_env do
      post "/mcp", params: jsonrpc_request("tools/call", {
        name: "list_account_statements",
        arguments: {}
      }).to_json, headers: mcp_headers(@token)

      assert_response :ok
      result = JSON.parse(response.body)["result"]
      assert_not result["isError"], "vault payload should not surface as a tool error"

      inner = JSON.parse(result["content"][0]["text"])
      assert inner["success"]

      payload = inner["statements"].find { |s| s["id"] == statement.id }
      assert_not_nil payload, "expected the created statement in the response"
      assert_equal statement.content_sha256, payload["content_sha256"]
      assert_equal accounts(:depository).id, payload.dig("account", "id")
    end
  end

  test "tools/call round-trips an upload through upload_account_statement" do
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    content = "date,amount\n2024-02-01,7\n"

    with_mcp_env do
      assert_difference "AccountStatement.count", 1 do
        post "/mcp", params: jsonrpc_request("tools/call", {
          name: "upload_account_statement",
          arguments: { filename: "uploaded.csv", content_base64: Base64.strict_encode64(content) }
        }).to_json, headers: mcp_headers(@token)
      end

      assert_response :ok
      result = JSON.parse(response.body)["result"]
      assert_not result["isError"]

      inner = JSON.parse(result["content"][0]["text"])
      assert inner["success"]
      assert_not inner["duplicate"]
      assert_equal Digest::SHA256.hexdigest(content), inner.dig("statement", "content_sha256")
    end
  end

  test "tools/call executes update_transaction" do
    with_mcp_env do
      transaction = transactions(:one)
      category = categories(:subcategory)

      post "/mcp", params: jsonrpc_request("tools/call", {
        name: "update_transaction",
        arguments: {
          id: transaction.id,
          category_id: category.id,
          notes: "Updated through MCP"
        }
      }).to_json, headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      result = body["result"]
      inner = JSON.parse(result["content"][0]["text"])

      assert_equal true, inner["success"]
      assert_equal category.id, transaction.reload.category_id
      assert_equal "Updated through MCP", transaction.entry.notes
    end
  end

  test "tools/call executes update_budget" do
    with_mcp_env do
      budget = budgets(:one)

      post "/mcp", params: jsonrpc_request("tools/call", {
        name: "update_budget",
        arguments: {
          budgeted_spending: 6200,
          expected_income: 8800
        }
      }).to_json, headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      result = body["result"]
      inner = JSON.parse(result["content"][0]["text"])

      assert_equal true, inner["success"]
      budget.reload
      assert_equal 6200, budget.budgeted_spending
      assert_equal 8800, budget.expected_income
    end
  end

  test "tools/call wraps function errors as isError response" do
    with_mcp_env do
      # Force a function error by stubbing
      Assistant::Function::GetBalanceSheet.any_instance.stubs(:call).raises(StandardError, "test error")

      post "/mcp", params: jsonrpc_request("tools/call", {
        name: "get_balance_sheet",
        arguments: {}
      }).to_json, headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      result = body["result"]

      assert result["isError"], "Expected isError to be true"
      inner = JSON.parse(result["content"][0]["text"])

      # The raised text is written for a log, not for an external client: a
      # RecordNotFound carries the access-control SQL and a range error carries
      # the column definition. The client learns which tool failed; the detail
      # stays server-side.
      assert_equal "The tool failed to run", inner["error"]
      assert_equal "get_balance_sheet", inner["tool"]
      assert_no_match(/test error/, response.body)
    end
  end

  # -- Session isolation --

  test "does not persist sessions or inherit impersonation state" do
    with_mcp_env do
      assert_no_difference "Session.count" do
        post "/mcp", params: jsonrpc_request("initialize").to_json,
             headers: mcp_headers(@token)
      end

      assert_response :ok
    end
  end

  # -- JSON-RPC id preservation --

  test "preserves request id in successful response" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("initialize", {}, id: 42).to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal 42, body["id"]
    end
  end

  test "preserves string request id" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("initialize", {}, id: "req-abc-123").to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal "req-abc-123", body["id"]
    end
  end

  private

    def with_mcp_env(&block)
      with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => @user.email, &block) # pipelock:ignore
    end

    def create_oauth_token(scope:, user: @user)
      app = Doorkeeper::Application.create!(
        name: "Test MCP Client #{SecureRandom.hex(4)}",
        redirect_uri: "https://claude.ai/callback",
        confidential: false
      )
      Doorkeeper::AccessToken.create!( # pipelock:ignore
        application: app,
        resource_owner_id: user.id,
        scopes: scope,
        expires_in: 1.year
      )
    end

    def with_mcp_cache
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = original_cache
    end

    def mcp_headers(token)
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{token}"
      }
    end

    def jsonrpc_request(method, params = {}, id: 1)
      { jsonrpc: "2.0", id: id, method: method, params: params }
    end

    def jsonrpc_notification(method, params = {})
      { jsonrpc: "2.0", method: method, params: params }
    end

    def assert_mcp_initialize_response(result)
      assert_equal MCP_PROTOCOL_VERSION, result["protocolVersion"]
      assert_match(/\A[0-9a-f-]{36}\z/, result["sessionId"])
      assert_equal MCP_PROTOCOL_VERSION, response.headers["Mcp-Protocol-Version"]
      assert_equal result["sessionId"], response.headers["Mcp-Session-Id"]
    end
end
