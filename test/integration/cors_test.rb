# frozen_string_literal: true

require "test_helper"

# CORS is now driven by ALLOWED_ORIGINS / APP_DOMAIN env vars (see F-02).
# The test environment does not set either, so Rack::Cors is loaded with an
# empty origin allowlist and MUST NOT echo back any Origin.
class CorsTest < ActionDispatch::IntegrationTest
  EVIL_ORIGIN = "http://evil.example.com"

  def assert_cors_header_absent(msg = nil)
    assert_nil response.headers["Access-Control-Allow-Origin"], msg
  end

  test "rack cors is configured in middleware stack" do
    middleware_classes = Rails.application.middleware.map(&:klass)
    assert_includes middleware_classes, Rack::Cors, "Rack::Cors should be in middleware stack"
  end

  test "cors does not reflect wildcard origin for api endpoints" do
    get "/api/v1/usage", headers: { "Origin" => EVIL_ORIGIN }
    assert_cors_header_absent
  end

  test "cors preflight does not allow arbitrary origin for api endpoints" do
    options "/api/v1/transactions",
      headers: {
        "Origin" => EVIL_ORIGIN,
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "Content-Type, Authorization"
      }
    assert_cors_header_absent
  end

  test "cors does not reflect wildcard origin for oauth token endpoint" do
    post "/oauth/token",
      params: { grant_type: "authorization_code", code: "test" },
      headers: { "Origin" => EVIL_ORIGIN }
    assert_cors_header_absent
  end

  test "cors preflight does not allow arbitrary origin for oauth token endpoint" do
    options "/oauth/token",
      headers: {
        "Origin" => EVIL_ORIGIN,
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "Content-Type"
      }
    assert_cors_header_absent
  end

  test "cors does not reflect wildcard origin for oauth revoke endpoint" do
    post "/oauth/revoke",
      params: { token: "test-token" },
      headers: { "Origin" => EVIL_ORIGIN }
    assert_cors_header_absent
  end

  test "cors preflight does not allow arbitrary origin for oauth revoke endpoint" do
    options "/oauth/revoke",
      headers: {
        "Origin" => EVIL_ORIGIN,
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "Content-Type"
      }
    assert_cors_header_absent
  end

  test "cors does not reflect wildcard origin for session endpoints" do
    post "/sessions",
      params: { email: "test@example.com", password: "password" },
      headers: { "Origin" => EVIL_ORIGIN }
    assert_cors_header_absent
  end

  test "cors preflight does not allow arbitrary origin for session endpoints" do
    options "/sessions/new",
      headers: {
        "Origin" => EVIL_ORIGIN,
        "Access-Control-Request-Method" => "GET",
        "Access-Control-Request-Headers" => "Content-Type"
      }
    assert_cors_header_absent
  end
end
