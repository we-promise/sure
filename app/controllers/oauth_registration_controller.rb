class OauthRegistrationController < ApplicationController
  include OauthBase

  LOOPBACK_HOSTS = [ "localhost", "127.0.0.1", "::1" ].freeze
  # Schemes that can execute script, read local files, invoke device handlers,
  # or are not OAuth redirects.
  FORBIDDEN_SCHEMES = %w[javascript data file about blob ws wss ftp mailto tel sms intent].freeze
  SCHEME_PATTERN = /\A[a-z][a-z0-9+\-.]*\z/.freeze

  VALID_SCOPES = OauthBase.mcp_scopes
  # Least privilege by default: a client that does not ask for read_write does
  # not get it. A client that wants MCP writes must say so explicitly.
  DEFAULT_SCOPE = "read"

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

    scope = resolve_requested_scope(body["scope"])
    return if performed?

    app = Doorkeeper::Application.new(
      name: client_name,
      redirect_uri: redirect_uris.join("\n"),
      confidential: false,
      scopes: scope
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

    # RFC 7591 §2's "scope" is a space-delimited string ("read read_write"),
    # but tolerate an array too rather than reject it outright. Blank/absent
    # falls back to DEFAULT_SCOPE. Any token outside VALID_SCOPES is rejected
    # rather than dropped, so a typo cannot silently register a narrower (or
    # wider) client than the caller asked for. Renders and returns nil on
    # rejection; the caller checks `performed?`.
    def resolve_requested_scope(raw)
      return DEFAULT_SCOPE if raw.blank?

      requested = Array(raw).join(" ").split.uniq
      unknown = requested - VALID_SCOPES

      if unknown.any?
        render json: {
          error: "invalid_client_metadata",
          error_description: t("oauth.registration.invalid_scope", scopes: unknown.join(", "))
        }, status: :bad_request
        return nil
      end

      requested.include?("read_write") ? "read_write" : "read"
    end

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
