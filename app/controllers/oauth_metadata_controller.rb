class OauthMetadataController < ApplicationController
  include OauthBase

  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade, raise: false
  skip_before_action :set_default_chat, raise: false
  skip_before_action :detect_os, raise: false

  def protected_resource
    render json: {
      resource: configured_base_url,
      authorization_servers: [ configured_base_url ]
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
      scopes_supported: [ "read_write" ]
    }
  end
end
