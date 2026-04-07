class McpController < ApplicationController
  PROTOCOL_VERSION = "2025-03-26"

  # Skip session-based auth and CSRF — this is a token-authenticated API
  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade
  skip_before_action :set_default_chat
  skip_before_action :detect_os

  before_action :authenticate_mcp_token!

  def handle
    body = parse_request_body
    return if performed?

    unless valid_jsonrpc?(body)
      render_jsonrpc_error(body&.dig("id"), -32600, "Invalid Request")
      return
    end

    request_id = body["id"]

    # JSON-RPC notifications omit the id field — server must not respond
    unless body.key?("id")
      return head(:no_content)
    end

    result = dispatch_jsonrpc(request_id, body["method"], body["params"])
    return if performed?

    render json: { jsonrpc: "2.0", id: request_id, result: result }
  end

  private

    def parse_request_body
      JSON.parse(request.raw_post)
    rescue JSON::ParserError
      render_jsonrpc_error(nil, -32700, "Parse error")
      nil
    end

    def valid_jsonrpc?(body)
      body.is_a?(Hash) && body["jsonrpc"] == "2.0" && body["method"].present?
    end

    def dispatch_jsonrpc(request_id, method, params)
      case method
      when "initialize"
        handle_initialize
      when "tools/list"
        handle_tools_list
      when "tools/call"
        handle_tools_call(request_id, params)
      else
        render_jsonrpc_error(request_id, -32601, "Method not found: #{method}")
        nil
      end
    end

    def handle_initialize
      {
        protocolVersion: PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: "sure", version: "1.0" }
      }
    end

    def handle_tools_list
      tools = Assistant.function_classes.map do |fn_class|
        fn_instance = fn_class.new(mcp_user)
        {
          name: fn_instance.name,
          description: fn_instance.description,
          inputSchema: fn_instance.params_schema
        }
      end

      { tools: tools }
    end

    def handle_tools_call(request_id, params)
      name = params&.dig("name")
      arguments = params&.dig("arguments") || {}

      fn_class = Assistant.function_classes.find { |fc| fc.name == name }

      unless fn_class
        render_jsonrpc_error(request_id, -32602, "Unknown tool: #{name}")
        return nil
      end

      fn = fn_class.new(mcp_user)
      result = fn.call(arguments)

      { content: [ { type: "text", text: result.to_json } ] }
    rescue => e
      Rails.logger.error "MCP tools/call error: #{e.message}"
      { content: [ { type: "text", text: { error: e.message }.to_json } ], isError: true }
    end

    def authenticate_mcp_token!
      expected = ENV["MCP_API_TOKEN"]

      unless expected.present?
        render json: { error: "MCP endpoint not configured" }, status: :service_unavailable
        return
      end

      token = request.headers["Authorization"]&.delete_prefix("Bearer ")&.strip

      unless ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected)
        render json: { error: "unauthorized" }, status: :unauthorized
        return
      end

      setup_mcp_user
    end

    def setup_mcp_user
      email = ENV["MCP_USER_EMAIL"]
      @mcp_user = User.find_by(email: email) if email.present?

      unless @mcp_user
        render json: { error: "MCP user not configured" }, status: :service_unavailable
        return
      end

      # Build a fresh session to avoid inheriting impersonation state from
      # existing sessions (Current.user resolves via active_impersonator_session
      # first, which could leak another user's data into MCP tool calls).
      Current.session = @mcp_user.sessions.build(
        user_agent: request.user_agent,
        ip_address: request.ip
      )
    end

    def mcp_user
      @mcp_user
    end

    def render_jsonrpc_error(id, code, message)
      render json: {
        jsonrpc: "2.0",
        id: id,
        error: { code: code, message: message }
      }
    end
end
