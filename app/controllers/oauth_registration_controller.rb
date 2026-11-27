class OauthRegistrationController < ApplicationController
  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade, raise: false
  skip_before_action :set_default_chat, raise: false
  skip_before_action :detect_os, raise: false

  rescue_from ActionDispatch::Http::Parameters::ParseError do
    render json: {
      error: "invalid_client_metadata",
      error_description: "Invalid JSON"
    }, status: :bad_request
  end

  # Registers a public OAuth client from MCP dynamic client registration.
  def create
    body = JSON.parse(request.raw_post)

    redirect_uris = Oauth::ClientMetadataValidator.normalize_redirect_uris(body["redirect_uris"])
    if redirect_uris.empty?
      render json: {
        error: "invalid_client_metadata",
        error_description: "redirect_uris is required"
      }, status: :bad_request
      return
    end

    unless redirect_uris.all? { |uri| Oauth::ClientMetadataValidator.valid_redirect_uri?(uri) }
      render json: {
        error: "invalid_client_metadata",
        error_description: t("oauth.registration.invalid_redirect_uris")
      }, status: :bad_request
      return
    end

    client_name = body["client_name"].presence || "MCP Client"

    if Oauth::ClientMetadataValidator.bidi_control?(client_name)
      render json: {
        error: "invalid_client_metadata",
        error_description: t("oauth.registration.invalid_client_name")
      }, status: :bad_request
      return
    end

    if Oauth::ClientMetadataValidator.reserved_client_name?(client_name)
      render json: {
        error: "invalid_client_metadata",
        error_description: t("oauth.registration.reserved_client_name")
      }, status: :bad_request
      return
    end

    app = Doorkeeper::Application.new(
      name: client_name,
      redirect_uri: redirect_uris.join("\n"),
      confidential: false,
      # MCP requires the read_write scope. Without assigning it to the
      # dynamically registered client, Doorkeeper falls back to the provider's
      # default read scope and the token is rejected by McpController.
      scopes: "read_write"
    )

    if app.save
      render json: {
        client_id: app.uid,
        client_name: app.name,
        redirect_uris: app.redirect_uri.split("\n"),
        grant_types: [ "authorization_code" ],
        token_endpoint_auth_method: "none"
      }, status: :created
    else
      render json: {
        error: "invalid_client_metadata",
        error_description: app.errors.full_messages.join(", ")
      }, status: :bad_request
    end
  rescue JSON::ParserError
    render json: {
      error: "invalid_client_metadata",
      error_description: "Invalid JSON"
    }, status: :bad_request
  end
end
