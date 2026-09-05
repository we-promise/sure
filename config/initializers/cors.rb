# frozen_string_literal: true

# CORS configuration for API access from mobile clients (Flutter) and other external apps.
#
# This enables Cross-Origin Resource Sharing for the /api, /oauth, and /sessions endpoints,
# allowing the Flutter mobile client and other authorized clients to communicate
# with the Rails backend.
#
# The allowed origins come from ALLOWED_ORIGINS or APP_DOMAIN; see CorsOrigins.
# Native mobile clients send no Origin header and are unaffected by any of this.

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Consulted per request rather than expanded once at boot, so the allow-list
    # follows the environment instead of the moment the process started. The
    # match is exact: an origin is a scheme, host and port, and prefix matching
    # here is how "https://app.example.com.evil.test" gets let in.
    origins do |source, _env|
      CorsOrigins.list.include?(source)
    end

    # API endpoints for mobile client and third-party integrations
    resource "/api/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      expose: %w[X-Request-Id X-Runtime],
      max_age: 86400

    # OAuth endpoints for authentication flows
    resource "/oauth/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      expose: %w[X-Request-Id X-Runtime],
      max_age: 86400

    # Session endpoints for webview-based authentication
    resource "/sessions/*",
      headers: :any,
      methods: %i[get post delete options head],
      expose: %w[X-Request-Id X-Runtime],
      max_age: 86400
  end
end
