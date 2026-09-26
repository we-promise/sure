# frozen_string_literal: true

require "test_helper"

class CorsTest < ActionDispatch::IntegrationTest
  test "rack cors is configured in middleware stack" do
    middleware_classes = Rails.application.middleware.map(&:klass)
    assert_includes middleware_classes, Rack::Cors, "Rack::Cors should be in middleware stack"
  end

  # Nothing configures an allow-list in the test environment, so an arbitrary
  # origin gets no Access-Control-Allow-Origin header at all and the browser
  # falls back to its same-origin default. These used to assert "*".
  test "an origin that is not on the allow-list gets no CORS grant" do
    get "/api/v1/usage", headers: { "Origin" => "http://evil.example" }

    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "no request is ever answered with a wildcard origin" do
    [ "/api/v1/usage", "/sessions/new" ].each do |path|
      get path, headers: { "Origin" => "http://evil.example" }
      assert_not_equal "*", response.headers["Access-Control-Allow-Origin"], "#{path} answered with a wildcard"
    end
  end

  test "a preflight from an origin that is not allowed is not granted" do
    options "/api/v1/transactions",
      headers: {
        "Origin" => "http://evil.example",
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "Content-Type, Authorization"
      }

    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "oauth endpoints are not granted to an origin that is not allowed" do
    post "/oauth/token",
      params: { grant_type: "authorization_code", code: "test" },
      headers: { "Origin" => "http://evil.example" }

    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "an oauth preflight from an origin that is not allowed is not granted" do
    options "/oauth/token",
      headers: {
        "Origin" => "http://evil.example",
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "Content-Type"
      }

    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "session endpoints are not granted to an origin that is not allowed" do
    post "/sessions",
      params: { email: "test@example.com", password: "password" },
      headers: { "Origin" => "http://evil.example" }

    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "a session preflight from an origin that is not allowed is not granted" do
    options "/sessions/new",
      headers: {
        "Origin" => "http://evil.example",
        "Access-Control-Request-Method" => "GET",
        "Access-Control-Request-Headers" => "Content-Type"
      }

    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "an allow-listed origin is granted, and only that origin" do
    CorsOrigins.stubs(:list).returns([ "https://app.example.com" ])

    get "/api/v1/usage", headers: { "Origin" => "https://app.example.com" }
    assert_equal "https://app.example.com", response.headers["Access-Control-Allow-Origin"]

    get "/api/v1/usage", headers: { "Origin" => "https://other.example.com" }
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  # A prefix match would let this through, which is why the check is equality.
  test "an origin that merely starts with an allowed one is refused" do
    CorsOrigins.stubs(:list).returns([ "https://app.example.com" ])

    get "/api/v1/usage", headers: { "Origin" => "https://app.example.com.evil.test" }

    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "an allow-listed origin gets a preflight grant" do
    CorsOrigins.stubs(:list).returns([ "https://app.example.com" ])

    options "/api/v1/transactions",
      headers: {
        "Origin" => "https://app.example.com",
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "Content-Type, Authorization"
      }

    assert_response :ok
    assert_equal "https://app.example.com", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Access-Control-Allow-Methods"], "POST"
  end
end
