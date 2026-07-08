class OauthRegistrationController < ApplicationController
  LOOPBACK_HOSTS = [ "localhost", "127.0.0.1", "::1" ].freeze

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

  def create
    body = JSON.parse(request.raw_post)

    redirect_uris = body["redirect_uris"]
    if redirect_uris.blank?
      render json: {
        error: "invalid_client_metadata",
        error_description: "redirect_uris is required"
      }, status: :bad_request
      return
    end

    redirect_uris = Array(redirect_uris).map { |u| u.to_s.strip }.reject(&:blank?)
    if redirect_uris.empty?
      render json: {
        error: "invalid_client_metadata",
        error_description: "redirect_uris is required"
      }, status: :bad_request
      return
    end

    unless redirect_uris.all? { |uri| valid_redirect_uri?(uri) }
      render json: {
        error: "invalid_client_metadata",
        error_description: "redirect_uris must use https or loopback http"
      }, status: :bad_request
      return
    end

    client_name = body["client_name"].presence || "MCP Client"

    app = Doorkeeper::Application.new(
      name: client_name,
      redirect_uri: redirect_uris.join("\n"),
      confidential: false
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

  private

    def valid_redirect_uri?(raw_uri)
      uri = URI.parse(raw_uri)
      return false if uri.host.blank?

      scheme = uri.scheme.to_s.downcase
      return true if scheme == "https"
      return false unless scheme == "http"

      host = uri.host.downcase.delete_prefix("[").delete_suffix("]")
      LOOPBACK_HOSTS.include?(host)
    rescue URI::InvalidURIError
      false
    end
end
