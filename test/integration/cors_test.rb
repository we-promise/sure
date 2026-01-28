# frozen_string_literal: true

require "test_helper"

class CorsTest < ActionDispatch::IntegrationTest
  test "rack cors is configured in middleware stack" do
    middleware_classes = Rails.application.middleware.map(&:klass)
    assert_includes middleware_classes, Rack::Cors, "Rack::Cors should be in middleware stack"
  end

  test "cors headers are returned for api endpoints" do
    get "/api/v1/usage", headers: { "Origin" => "http://localhost:3000" }

    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert response.headers["Access-Control-Expose-Headers"].present?
  end

  test "cors preflight request is handled for api endpoints" do
    # Simulate a preflight OPTIONS request
    options "/api/v1/transactions",
      headers: {
        "Origin" => "http://localhost:3000",
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "Content-Type, Authorization"
      }

    assert_response :ok
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert response.headers["Access-Control-Allow-Methods"].present?
    assert_includes response.headers["Access-Control-Allow-Methods"], "POST"
  end

  test "cors headers are returned for oauth endpoints" do
    post "/oauth/token",
      params: { grant_type: "authorization_code", code: "test" },
      headers: { "Origin" => "http://localhost:3000" }

    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  test "cors preflight request is handled for oauth endpoints" do
    options "/oauth/token",
      headers: {
        "Origin" => "http://localhost:3000",
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "Content-Type"
      }

    assert_response :ok
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  test "cors headers are returned for session endpoints" do
    post "/sessions",
      params: { email: "test@example.com", password: "password" },
      headers: { "Origin" => "http://localhost:3000" }

    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end

  test "cors preflight request is handled for session endpoints" do
    options "/sessions/new",
      headers: {
        "Origin" => "http://localhost:3000",
        "Access-Control-Request-Method" => "GET",
        "Access-Control-Request-Headers" => "Content-Type"
      }

    assert_response :ok
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end
end
