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
    [ "https://#{ENV['APP_DOMAIN']}" ]
  else
    Rails.logger.warn("[SECURITY] ALLOWED_ORIGINS and APP_DOMAIN not set — CORS will deny all cross-origin requests")
    []
  end
end

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*allowed_origins)

    resource "/api/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      expose: %w[X-Request-Id X-Runtime],
      max_age: 86400,
      credentials: true

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
