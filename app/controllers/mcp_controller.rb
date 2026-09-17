class McpController < ApplicationController
  include OauthBase

  PROTOCOL_VERSION = "2025-06-18"
  SUPPORTED_PROTOCOL_VERSIONS = [ "2025-03-26", PROTOCOL_VERSION ].freeze
  MCP_SESSION_TTL = 1.day

  # Skip session-based auth and CSRF — this is a token-authenticated API
  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade
  skip_before_action :set_default_chat
  skip_before_action :detect_os

  before_action :authenticate_mcp_token!
  after_action :set_mcp_response_headers

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
      return unless prepare_mcp_request_context(request_id, method, params)

      case method
      when "initialize"
        handle_initialize(params)
      when "tools/list"
        handle_tools_list
      when "tools/call"
        handle_tools_call(request_id, params)
      else
        render_jsonrpc_error(request_id, -32601, "Method not found: #{method}")
        nil
      end
    end

    def handle_initialize(params)
      @mcp_protocol_version = negotiated_protocol_version(params)
      @mcp_session_id = SecureRandom.uuid
      Rails.cache.write(mcp_session_cache_key(@mcp_session_id), mcp_user.id, expires_in: MCP_SESSION_TTL)

      {
        protocolVersion: @mcp_protocol_version,
        capabilities: { tools: {} },
        serverInfo: { name: "sure", version: "1.0" },
        sessionId: @mcp_session_id
      }
    end

    def handle_tools_list
      tools = Assistant.function_classes(mcp_user).map do |fn_class|
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

      # Scoped to the authenticated user so a tool hidden from tools/list is not
      # callable by guessing its name — a non-preview caller gets the same
      # "Unknown tool" response as for a name that does not exist.
      fn_class = Assistant.function_classes(mcp_user).find { |fc| fc.name == name }

      unless fn_class
        render_jsonrpc_error(request_id, -32602, "Unknown tool: #{name}")
        return nil
      end

      fn = fn_class.new(mcp_user)
      result = fn.call(arguments)

      { content: [ { type: "text", text: result.to_json } ] }
    rescue => e
      Rails.logger.error "MCP tools/call error: #{e.class}: #{e.message}"

      # Whatever the tool raised, its message was written for a log, not for an
      # external client: a RecordNotFound carries the access-control SQL, and a
      # PG range error carries the column definition. The full text stays in the
      # log above, where an operator can read it.
      { content: [ { type: "text", text: { error: "The tool failed to run", tool: name }.to_json } ], isError: true }
    end

    def authenticate_mcp_token!
      auth_header = request.authorization.to_s
      token = auth_header[/\ABearer\s+(.+)\z/i, 1]&.strip&.presence # pipelock:ignore

      return if token.present? && authenticate_via_doorkeeper(token)
      return if token.present? && authenticate_via_env_token(token)

      render_mcp_unauthorized
    end

    def authenticate_via_doorkeeper(token)
      access_token = Doorkeeper::AccessToken.by_token(token)
      return false unless access_token&.accessible?
      return false unless access_token.scopes.include?("read_write")

      user = User.find_by(id: access_token.resource_owner_id)
      return false unless user&.active?

      setup_mcp_session(user)
      true
    end

    def authenticate_via_env_token(token)
      expected = ENV["MCP_API_TOKEN"]
      return false unless expected.present?
      return false unless ActiveSupport::SecurityUtils.secure_compare(
        OpenSSL::Digest::SHA256.hexdigest(token),
        OpenSSL::Digest::SHA256.hexdigest(expected)
      )

      user = User.find_by(email: ENV["MCP_USER_EMAIL"])

      unless user
        Rails.logger.warn "[MCP] MCP_USER_EMAIL does not match any user — check environment configuration"
        return false
      end

      setup_mcp_session(user)
      true
    end

    def setup_mcp_session(user)
      @mcp_user = user
      # Build a fresh session to avoid inheriting impersonation state from
      # existing sessions (Current.user resolves via active_impersonator_session
      # first, which could leak another user's data into MCP tool calls).
      Current.session = user.sessions.build(
        user_agent: request.user_agent,
        ip_address: request.ip
      )
    end

    def mcp_user
      @mcp_user
    end

    def prepare_mcp_request_context(request_id, method, params)
      return true if method == "initialize"

      @mcp_protocol_version = mcp_request_header("Mcp-Protocol-Version").presence || PROTOCOL_VERSION

      unless SUPPORTED_PROTOCOL_VERSIONS.include?(@mcp_protocol_version)
        render_jsonrpc_error(
          request_id,
          -32600,
          t("mcp.errors.unsupported_protocol_version", version: @mcp_protocol_version),
          status: :bad_request
        )
        return false
      end

      session_id = mcp_request_header("Mcp-Session-Id").presence
      return true unless session_id

      unless Rails.cache.read(mcp_session_cache_key(session_id)) == mcp_user.id
        render_jsonrpc_error(request_id, -32600, t("mcp.errors.invalid_session_id"), status: :not_found)
        return false
      end

      @mcp_session_id = session_id
      true
    end

    def negotiated_protocol_version(params)
      requested_version = params&.dig("protocolVersion").presence || PROTOCOL_VERSION
      return requested_version if SUPPORTED_PROTOCOL_VERSIONS.include?(requested_version)

      PROTOCOL_VERSION
    end

    def mcp_session_cache_key(session_id)
      "mcp:session:#{session_id}"
    end

    def mcp_request_header(name)
      request.headers[name] || request.get_header("HTTP_#{name.upcase.tr('-', '_')}")
    end

    def render_mcp_unauthorized
      response.set_header(
        "WWW-Authenticate",
        "Bearer resource_metadata=\"#{configured_base_url}/.well-known/oauth-protected-resource\""
      )
      render json: { error: "unauthorized" }, status: :unauthorized
    end

    def render_jsonrpc_error(id, code, message, status: :ok, data: nil)
      error = { code: code, message: message }
      error[:data] = data if data

      render json: {
        jsonrpc: "2.0",
        id: id,
        error: error
      }, status: status
    end

    def set_mcp_response_headers
      response.set_header("Mcp-Protocol-Version", @mcp_protocol_version || PROTOCOL_VERSION)
      response.set_header("Mcp-Session-Id", @mcp_session_id) if @mcp_session_id.present?
    end
end
