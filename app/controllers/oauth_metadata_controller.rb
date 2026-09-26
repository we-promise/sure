class OauthMetadataController < ApplicationController
  include OauthBase

  MCP_SCOPES = OauthBase.mcp_scopes

  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade, raise: false
  skip_before_action :set_default_chat, raise: false
  skip_before_action :detect_os, raise: false

  # RFC 9728 §3.3: the "resource" value in the metadata document must match
  # the resource identifier a client constructed the metadata URL from. A
  # client fetching the root well-known path assumes the identifier is the
  # bare origin; a client fetching the resource-scoped path assumes
  # "<origin>/mcp". Serving the same "resource" from both endpoints (as this
  # used to) fails that check for spec-strict clients — see
  # modelcontextprotocol/typescript-sdk#2751 for this exact bug class.
  def protected_resource
    render json: protected_resource_metadata(configured_base_url)
  end

  def protected_resource_for_mcp
    render json: protected_resource_metadata("#{configured_base_url}/mcp")
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

  private
    def protected_resource_metadata(resource)
      {
        resource: resource,
        authorization_servers: [ configured_base_url ],
        scopes_supported: MCP_SCOPES
      }
    end
end
