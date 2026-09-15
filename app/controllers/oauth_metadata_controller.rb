class OauthMetadataController < ApplicationController
  include OauthBase

  # The only two scopes Doorkeeper is configured with (config/initializers/doorkeeper.rb).
  MCP_SCOPES = %w[read read_write].freeze

  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade, raise: false
  skip_before_action :set_default_chat, raise: false
  skip_before_action :detect_os, raise: false

  # RFC 9728 protected resource metadata. Served at both this root well-known
  # path (what McpController's WWW-Authenticate resource_metadata points at)
  # and at the resource-scoped path .well-known/oauth-protected-resource/mcp
  # (routes.rb), for clients that construct the metadata URL themselves from
  # the "resource" identifier below rather than following resource_metadata.
  # Both return identical content.
  def protected_resource
    render json: {
      # /mcp, not the app root, is the actual protected resource: it is the
      # one endpoint behind Bearer auth, distinct from the rest of the app.
      resource: "#{configured_base_url}/mcp",
      authorization_servers: [ configured_base_url ],
      scopes_supported: MCP_SCOPES
    }
  end

  def authorization_server
    render json: {
      issuer: configured_base_url,
      authorization_endpoint: "#{configured_base_url}/oauth/authorize",
      token_endpoint: "#{configured_base_url}/oauth/token",
      registration_endpoint: "#{configured_base_url}/register",
      response_types_supported: [ "code" ],
      grant_types_supported: [ "authorization_code" ],
      code_challenge_methods_supported: [ "S256" ],
      scopes_supported: MCP_SCOPES
    }
  end
end
