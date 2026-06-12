# frozen_string_literal: true

# CORS configuration for API access from mobile clients (Flutter) and other external apps.
#
# Allowed origins configured via ALLOWED_ORIGINS env var (comma-separated).
# Falls back to APP_DOMAIN if set, otherwise denies cross-origin requests.
#
# Examples:
#   ALLOWED_ORIGINS=https://app.example.com,https://staging.example.com
#   APP_DOMAIN=app.example.com
#
# Security: wildcard origins (*) are intentionally not used.

def allowed_origins
  if ENV["ALLOWED_ORIGINS"].present?
    ENV["ALLOWED_ORIGINS"].split(",").map(&:strip).reject(&:empty?)
  elsif ENV["APP_DOMAIN"].present?
    # Derive scheme from the app's SSL settings rather than hard-coding https://.
    # Environments that serve plain HTTP (no SSL termination configured, no
    # RAILS_ASSUME_SSL) need http:// or browser Origin: http://... never matches.
    scheme = if Rails.application.config.force_ssl ||
                Rails.application.config.respond_to?(:assume_ssl) && Rails.application.config.assume_ssl
      "https"
    else
      "http"
    end
    [ "#{scheme}://#{ENV['APP_DOMAIN']}" ]
  else
    Rails.logger.warn("[SECURITY] ALLOWED_ORIGINS and APP_DOMAIN not set — CORS will deny all cross-origin requests")
    []
  end
end

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*allowed_origins)

    # NOTE: /api/* does NOT set credentials: true. Mobile / external API clients
    # authenticate via Authorization: Bearer or X-Api-Key headers, neither of
    # which require credentials: true to be forwarded by browsers. Keeping
    # credentials off here means a misconfigured ALLOWED_ORIGINS (untrusted
    # origin slipping in) cannot lead to cross-origin cookie exfiltration.
    # The /sessions/* resource below DOES set credentials: true because the
    # web session is cookie-based.
    resource "/api/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      expose: %w[X-Request-Id X-Runtime],
      max_age: 86400

    resource "/oauth/token",
      headers: :any,
      methods: %i[post options],
      max_age: 86400

    resource "/oauth/revoke",
      headers: :any,
      methods: %i[post options],
      max_age: 86400

    resource "/sessions/*",
      headers: :any,
      methods: %i[get post delete options head],
      expose: %w[X-Request-Id X-Runtime],
      max_age: 86400,
      credentials: true
  end
end
