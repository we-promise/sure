class OauthRegistrationController < ApplicationController
  LOOPBACK_HOSTS = [ "localhost", "127.0.0.1", "::1" ].freeze
  # Schemes that can execute script, read local files, invoke device handlers,
  # or are not OAuth redirects.
  FORBIDDEN_SCHEMES = %w[javascript data file about blob ws wss ftp mailto tel sms intent].freeze
  SCHEME_PATTERN = /\A[a-z][a-z0-9+\-.]*\z/.freeze

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
        error_description: t("oauth.registration.invalid_redirect_uris")
      }, status: :bad_request
      return
    end

    client_name = body["client_name"].presence || "MCP Client"

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

  private

    # Returns true for https, loopback http, and RFC 8252 private-use schemes
    # (cursor://, vscode://). Rejects fragments, userinfo, handler schemes, and
    # non-loopback http.
    def valid_redirect_uri?(raw_uri)
      uri = URI.parse(raw_uri)
      return false unless uri.fragment.nil?
      return false if uri.userinfo.present?

      scheme = uri.scheme.to_s.downcase
      return false if scheme.blank? || FORBIDDEN_SCHEMES.include?(scheme)
      return false unless scheme.match?(SCHEME_PATTERN)

      case scheme
      when "https"
        uri.host.present?
      when "http"
        loopback_http?(uri)
      else
        native_app_redirect?(uri)
      end
    rescue URI::Error
      false
    end

    # Returns true when +uri+ is http to localhost, 127.0.0.1, or ::1.
    def loopback_http?(uri)
      return false if uri.host.blank?

      host = uri.host.downcase.delete_prefix("[").delete_suffix("]")
      LOOPBACK_HOSTS.include?(host)
    end

    # Returns true when a private-use URI has a host or path to redirect to.
    def native_app_redirect?(uri)
      uri.host.present? || uri.path.present?
    end
end
