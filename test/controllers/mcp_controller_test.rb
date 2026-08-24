require "test_helper"

class McpControllerTest < ActionDispatch::IntegrationTest
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
    assert_equal "2025-03-26", result["protocolVersion"]
  end

  test "authenticates a token issued to a dynamically registered MCP client" do
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
    assert_equal "read_write", token_response["scope"]

    post "/mcp", params: jsonrpc_request("initialize").to_json,
         headers: mcp_headers(token_response["access_token"])

    assert_response :ok
    assert_equal "2025-03-26", JSON.parse(response.body).dig("result", "protocolVersion")
  end

  test "rejects token with read-only scope" do
    app = Doorkeeper::Application.create!(
      name: "Test MCP Client #{SecureRandom.hex(4)}",
      redirect_uri: "https://claude.ai/callback",
      confidential: false
    )
    token = Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: app,
      resource_owner_id: @user.id,
      scopes: "read",
      expires_in: 1.year
    )

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

  test "notifications receive no response body" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_notification("notifications/initialized").to_json,
           headers: mcp_headers(@token)

      assert_response :no_content
      assert response.body.blank?, "Notification must not produce a response body"
    end
  end

  test "tools/call sent as notification does not execute" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_notification("tools/call", { name: "get_balance_sheet", arguments: {} }).to_json,
           headers: mcp_headers(@token)

      assert_response :no_content
      assert response.body.blank?, "Notification-style tools/call must not execute or respond"
    end
  end

  test "unknown notification method still returns no content" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_notification("notifications/unknown").to_json,
           headers: mcp_headers(@token)

      assert_response :no_content
      assert response.body.blank?
    end
  end

  # -- initialize --

  test "initialize returns server info and capabilities" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("initialize", { protocolVersion: "2025-03-26" }).to_json,
           headers: mcp_headers(@token)

      assert_response :ok
      body = JSON.parse(response.body)
      result = body["result"]

      assert_equal "2.0", body["jsonrpc"]
      assert_equal 1, body["id"]
      assert_equal "2025-03-26", result["protocolVersion"]
      assert_equal "sure", result["serverInfo"]["name"]
      assert result["capabilities"].key?("tools")
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
      assert_equal "test error", inner["error"]
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
end
