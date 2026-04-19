# frozen_string_literal: true

require "test_helper"

# CORS is now driven by ALLOWED_ORIGINS / APP_DOMAIN env vars (see F-02).
# The test environment does not set either, so Rack::Cors is loaded with an
# empty origin allowlist and MUST NOT echo back any Origin.
class CorsTest < ActionDispatch::IntegrationTest
  test "rack cors is configured in middleware stack" do
    middleware_classes = Rails.application.middleware.map(&:klass)
    assert_includes middleware_classes, Rack::Cors, "Rack::Cors should be in middleware stack"
  end

  test "cors does not reflect wildcard origin for api endpoints" do
    get "/api/v1/usage", headers: { "Origin" => "http://evil.example.com" }

    assert_not_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_not_equal "http://evil.example.com", response.headers["Access-Control-Allow-Origin"]
  end

  test "cors preflight does not allow arbitrary origin for api endpoints" do
    options "/api/v1/transactions",
      headers: {
        "Origin" => "http://evil.example.com",
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "Content-Type, Authorization"
      }

    # With an empty allowlist rack-cors should not echo the origin back.
    assert_not_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_not_equal "http://evil.example.com", response.headers["Access-Control-Allow-Origin"]
  end

  test "cors does not reflect wildcard origin for oauth token endpoint" do
    post "/oauth/token",
      params: { grant_type: "authorization_code", code: "test" },
      headers: { "Origin" => "http://evil.example.com" }

    assert_not_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_not_equal "http://evil.example.com", response.headers["Access-Control-Allow-Origin"]
  end

  test "cors preflight does not allow arbitrary origin for oauth token endpoint" do
    options "/oauth/token",
      headers: {
        "Origin" => "http://evil.example.com",
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "Content-Type"
      }

    assert_not_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_not_equal "http://evil.example.com", response.headers["Access-Control-Allow-Origin"]
  end

  test "cors does not reflect wildcard origin for session endpoints" do
    post "/sessions",
      params: { email: "test@example.com", password: "password" },
      headers: { "Origin" => "http://evil.example.com" }

    assert_not_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_not_equal "http://evil.example.com", response.headers["Access-Control-Allow-Origin"]
  end

  test "cors preflight does not allow arbitrary origin for session endpoints" do
    options "/sessions/new",
      headers: {
        "Origin" => "http://evil.example.com",
        "Access-Control-Request-Method" => "GET",
        "Access-Control-Request-Headers" => "Content-Type"
      }

    assert_not_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_not_equal "http://evil.example.com", response.headers["Access-Control-Allow-Origin"]
  end
end
