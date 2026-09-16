class McpController < ApplicationController
  include OauthBase

  LEGACY_PROTOCOL_VERSION = "2025-03-26"
  PROTOCOL_VERSION = "2025-06-18"
  # MCP's stateless dialect (see modelcontextprotocol.io/specification/2026-07-28/changelog):
  # no initialize/notifications/initialized handshake and no Mcp-Session-Id —
  # every request carries its own protocol version, and every result carries
  # resultType plus the server's identity in _meta. server/discover is this
  # dialect's session-less capability probe. Any 2026-07-28 client works the
  # same way, ChatGPT's tunnel included; nothing here is tunnel-specific.
  MODERN_PROTOCOL_VERSION = "2026-07-28"
  SUPPORTED_PROTOCOL_VERSIONS = [ LEGACY_PROTOCOL_VERSION, PROTOCOL_VERSION, MODERN_PROTOCOL_VERSION ].freeze
  MCP_SESSION_TTL = 1.day
  SERVER_INFO = { name: "sure", version: "1.0" }.freeze
  # See authenticate_via_env_token below.
  MCP_API_TOKEN_SCOPES = OauthBase.mcp_scopes

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

    # JSON-RPC notifications omit the id field — server must not send a body.
    # MCP Streamable HTTP answers a notification with 202 Accepted (204 is for
    # "processed, nothing to say"; 202 is "accepted, no reply is coming").
    unless body.key?("id")
      return head(:accepted)
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
      when "server/discover"
        handle_server_discover
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
      Rails.cache.write(
        mcp_session_cache_key(@mcp_session_id),
        { user_id: mcp_user.id, access_mode: @mcp_access_mode.to_s },
        expires_in: MCP_SESSION_TTL
      )

      {
        protocolVersion: @mcp_protocol_version,
        capabilities: { tools: {} },
        serverInfo: SERVER_INFO,
        sessionId: @mcp_session_id
      }
    end

    # Authenticated, session-less capability probe for the 2026-07-28 dialect.
    # Deliberately does not touch session state: no Mcp-Session-Id is minted or
    # read, so a client can call this before (or instead of) initialize — or,
    # per that dialect's spec, instead of ever calling initialize at all.
    def handle_server_discover
      {
        resultType: "complete",
        supportedVersions: SUPPORTED_PROTOCOL_VERSIONS.reverse,
        capabilities: { tools: {} },
        _meta: { "io.modelcontextprotocol/serverInfo" => SERVER_INFO }
      }
    end

    def handle_tools_list
      tools = mcp_function_classes.map do |fn_class|
        fn_instance = fn_class.new(mcp_user)
        {
          name: fn_instance.name,
          description: fn_instance.description,
          inputSchema: fn_instance.params_schema
        }
      end

      modern_complete_result({ tools: tools })
    end

    def handle_tools_call(request_id, params)
      name = params&.dig("name")
      arguments = params&.dig("arguments") || {}

      # Scoped to mcp_function_classes, which already applies both the preview
      # gate and the read-only allowlist — a write tool hidden from tools/list
      # by either filter is equally unreachable here. A read-only caller who
      # knows a write tool's exact name gets the same "Unknown tool" response
      # as a name that does not exist; there is no separate "forbidden" path
      # that would confirm the tool exists.
      fn_class = mcp_function_classes.find { |fc| fc.name == name }

      unless fn_class
        render_jsonrpc_error(request_id, -32602, "Unknown tool: #{name}")
        return nil
      end

      fn = fn_class.new(mcp_user)
      result = fn.call(arguments)

      modern_complete_result({ content: [ { type: "text", text: result.to_json } ] })
    rescue => e
      Rails.logger.error "MCP tools/call error: #{e.class}: #{e.message}"

      # Whatever the tool raised, its message was written for a log, not for an
      # external client: a RecordNotFound carries the access-control SQL, and a
      # PG range error carries the column definition. The full text stays in the
      # log above, where an operator can read it.
      modern_complete_result({ content: [ { type: "text", text: { error: "The tool failed to run", tool: name }.to_json } ], isError: true })
    end

    def authenticate_mcp_token!
      auth_header = request.authorization.to_s
      token = auth_header[/\ABearer\s+(.+)\z/i, 1]&.strip&.presence # pipelock:ignore

      return if token.present? && authenticate_via_doorkeeper(token)
      return if token.present? && authenticate_via_env_token(token)

      render_mcp_unauthorized
    end

    # Doorkeeper is already configured with the only two scopes MCP cares
    # about (config/initializers/doorkeeper.rb: default_scopes :read,
    # optional_scopes :read_write) — reused as-is rather than introducing a
    # parallel scope system. "read_write" implies "read", so a token carrying
    # both (possible if a client explicitly requests the superset) is treated
    # as read_write. A token with neither scope is not a valid MCP credential,
    # regardless of what else Doorkeeper considers it authorized for.
    def authenticate_via_doorkeeper(token)
      access_token = Doorkeeper::AccessToken.by_token(token)
      return false unless access_token&.accessible?

      access_mode = doorkeeper_mcp_access_mode(access_token.scopes)
      return false unless access_mode

      user = User.find_by(id: access_token.resource_owner_id)
      return false unless user&.active?

      setup_mcp_session(user)
      @mcp_access_mode = access_mode
      true
    end

    def doorkeeper_mcp_access_mode(scopes)
      return :read_write if scopes.include?("read_write")
      return :read_only if scopes.include?("read")

      nil
    end

    # MCP_API_TOKEN_SCOPE lets a self-hosted install pin the static bearer
    # token to the same read/read_write levels OAuth uses, instead of a
    # separate second token. Unset keeps the historical default: full access,
    # so existing installs see no change. An explicit but unrecognized value
    # fails the authentication rather than silently granting read_write —
    # a typo here must never widen access.
    def authenticate_via_env_token(token)
      expected = ENV["MCP_API_TOKEN"]
      return false unless expected.present?
      return false unless ActiveSupport::SecurityUtils.secure_compare(
        OpenSSL::Digest::SHA256.hexdigest(token),
        OpenSSL::Digest::SHA256.hexdigest(expected)
      )

      scope = ENV["MCP_API_TOKEN_SCOPE"].presence || "read_write"
      unless MCP_API_TOKEN_SCOPES.include?(scope)
        Rails.logger.warn "[MCP] MCP_API_TOKEN_SCOPE=#{scope.inspect} is invalid (must be \"read\" or \"read_write\") — check environment configuration"
        return false
      end

      user = User.find_by(email: ENV["MCP_USER_EMAIL"])

      unless user
        Rails.logger.warn "[MCP] MCP_USER_EMAIL does not match any user — check environment configuration"
        return false
      end

      setup_mcp_session(user)
      @mcp_access_mode = scope == "read_write" ? :read_write : :read_only
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

    # A global kill-switch: when set, every connection is limited to read-only
    # tools regardless of how it authenticated (OAuth scope or the static
    # MCP_API_TOKEN_SCOPE). @mcp_access_mode alone covers the per-credential case.
    def mcp_read_only?
      ActiveModel::Type::Boolean.new.cast(ENV["MCP_READ_ONLY"]) || @mcp_access_mode == :read_only
    end

    # Single source of truth for both tools/list and tools/call: filtering only
    # tools/list would hide write tools from discovery while leaving them
    # callable by a client that already knows (or guesses) their name.
    #
    # Each class answers its own Assistant::Function.read_only? (false unless
    # explicitly overridden — see that base class), so classifying a tool is a
    # one-line change on the class itself rather than a list to keep in sync
    # here. A preview tool is still gated first by Assistant.function_classes:
    # being read-only never makes a tool reachable for a user without preview
    # features on.
    def mcp_function_classes
      classes = Assistant.function_classes(mcp_user)
      return classes unless mcp_read_only?

      classes.select(&:read_only?)
    end

    def prepare_mcp_request_context(request_id, method, params)
      return true if method == "initialize"

      header_version = mcp_request_header("Mcp-Protocol-Version").presence
      meta_version = params&.dig("_meta", "io.modelcontextprotocol/protocolVersion").presence

      if header_version && meta_version && header_version != meta_version
        render_jsonrpc_error(
          request_id,
          -32600,
          t("mcp.errors.protocol_version_mismatch", header: header_version, meta: meta_version),
          status: :bad_request
        )
        return false
      end

      @mcp_protocol_version = header_version || meta_version || PROTOCOL_VERSION

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

      unless valid_mcp_session?(session_id)
        render_jsonrpc_error(request_id, -32600, t("mcp.errors.invalid_session_id"), status: :not_found)
        return false
      end

      @mcp_session_id = session_id
      true
    end

    # Backward-compatible with cache entries written before this patch, which
    # stored the bare user id (every credential was read_write back then, so
    # that is exactly what a legacy entry means — not an ambiguity to resolve
    # in the caller's favor). A session never grants more access than the
    # credential that created it: if the session was minted read-only, it stays
    # read-only for its full lifetime even if this request's own token is
    # read-write.
    def valid_mcp_session?(session_id)
      cached = Rails.cache.read(mcp_session_cache_key(session_id))

      user_id, session_access_mode =
        case cached
        when Hash
          [ cached[:user_id] || cached["user_id"], (cached[:access_mode] || cached["access_mode"])&.to_sym ]
        when String, Integer
          # Pre-patch entries stored the bare id (a UUID string on this
          # schema); every credential was read_write back then.
          [ cached, :read_write ]
        end

      return false unless user_id.present? && user_id == mcp_user&.id

      @mcp_access_mode = :read_only if session_access_mode == :read_only
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

    # 2026-07-28 clients expect a resultType and the server's identity
    # alongside otherwise-unchanged result payloads; 2025-dialect clients keep
    # the exact historical shape.
    def modern_mcp_request?
      @mcp_protocol_version == MODERN_PROTOCOL_VERSION
    end

    def modern_complete_result(payload)
      return payload unless modern_mcp_request?

      payload.merge(
        resultType: "complete",
        _meta: { "io.modelcontextprotocol/serverInfo" => SERVER_INFO }
      )
    end

    # scope="read" tells a client what to request first: the minimum needed to
    # get in the door at all. Least privilege by default, guided by the server
    # rather than left to whatever the client happens to default to.
    def render_mcp_unauthorized
      response.set_header(
        "WWW-Authenticate",
        "Bearer resource_metadata=\"#{configured_base_url}/.well-known/oauth-protected-resource\", scope=\"read\""
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
