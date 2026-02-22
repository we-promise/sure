require "test_helper"

class McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @token = "test-mcp-token-#{SecureRandom.hex(8)}"
  end

  # -- Authentication --

  test "returns 401 without authorization header" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("initialize").to_json,
           headers: { "Content-Type" => "application/json" }

      assert_response :unauthorized
      assert_equal "unauthorized", JSON.parse(response.body)["error"]
    end
  end

  test "returns 401 with wrong token" do
    with_mcp_env do
      post "/mcp", params: jsonrpc_request("initialize").to_json,
           headers: mcp_headers("wrong-token")

      assert_response :unauthorized
    end
  end

  test "returns 503 when MCP_API_TOKEN is not set" do
    with_env_overrides("MCP_USER_EMAIL" => @user.email) do
      post "/mcp", params: jsonrpc_request("initialize").to_json,
           headers: mcp_headers(@token)

      assert_response :service_unavailable
      assert_includes JSON.parse(response.body)["error"], "not configured"
    end
  end

  test "returns 503 when MCP_USER_EMAIL is not set" do
    with_env_overrides("MCP_API_TOKEN" => @token) do
      post "/mcp", params: jsonrpc_request("initialize").to_json,
           headers: mcp_headers(@token)

      assert_response :service_unavailable
      assert_includes JSON.parse(response.body)["error"], "user not configured"
    end
  end

  test "returns 503 when MCP_USER_EMAIL does not match any user" do
    with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => "nonexistent@example.com") do
      post "/mcp", params: jsonrpc_request("initialize").to_json,
           headers: mcp_headers(@token)

      assert_response :service_unavailable
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
      assert_equal Assistant.function_classes.size, tools.size

      tool_names = tools.map { |t| t["name"] }
      assert_includes tool_names, "get_transactions"
      assert_includes tool_names, "get_accounts"
      assert_includes tool_names, "get_holdings"
      assert_includes tool_names, "get_balance_sheet"
      assert_includes tool_names, "get_income_statement"

      # Each tool has required fields
      tools.each do |tool|
        assert tool["name"].present?, "Tool missing name"
        assert tool["description"].present?, "Tool #{tool['name']} missing description"
        assert tool["inputSchema"].present?, "Tool #{tool['name']} missing inputSchema"
        assert_equal "object", tool["inputSchema"]["type"]
      end
    end
  end

  # -- tools/call --

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
      with_env_overrides("MCP_API_TOKEN" => @token, "MCP_USER_EMAIL" => @user.email, &block)
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
