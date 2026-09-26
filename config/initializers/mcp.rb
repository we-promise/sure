# frozen_string_literal: true

# Fail loud at boot, not at the first confusing 401: MCP_API_TOKEN_SCOPE is
# already fail-closed at request time (McpController#authenticate_via_env_token
# rejects an unrecognized value rather than defaulting to full access), but a
# typo there would otherwise only surface as every static-token MCP request
# 401ing, with the reason sitting in a Rails.logger.warn nobody was watching.
Rails.application.config.after_initialize do
  scope = ENV["MCP_API_TOKEN_SCOPE"]

  if scope.present? && !OauthBase.mcp_scopes.include?(scope)
    raise "MCP_API_TOKEN_SCOPE=#{scope.inspect} is invalid — must be one of " \
          "#{OauthBase.mcp_scopes.join(', ')} (or unset, which defaults to read_write)."
  end
end
