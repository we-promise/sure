# frozen_string_literal: true

# CORS configuration for API access from mobile clients (Flutter) and other external apps.
#
# This enables Cross-Origin Resource Sharing for the /api, /oauth, and /sessions endpoints,
# allowing the Flutter mobile client and other authorized clients to communicate
# with the Rails backend.

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Allow requests from any origin for API endpoints
    # Mobile apps and development environments need flexible CORS
    origins "*"

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
