# frozen_string_literal: true

require "test_helper"

class RackAttackTest < ActionDispatch::IntegrationTest
  test "rack attack is configured" do
    # Verify Rack::Attack is enabled in middleware stack
    middleware_classes = Rails.application.middleware.map(&:klass)
    assert_includes middleware_classes, Rack::Attack, "Rack::Attack should be in middleware stack"
  end

  test "oauth token endpoint has rate limiting configured" do
    # Test that the throttle is configured (we don't need to trigger it)
    throttles = Rack::Attack.throttles.keys
    assert_includes throttles, "oauth/token", "OAuth token endpoint should have rate limiting"
  end

  test "api requests have rate limiting configured" do
    # Test that API rate limiting is configured
    throttles = Rack::Attack.throttles.keys
    assert_includes throttles, "api/requests", "API requests should have rate limiting"
  end

  test "POST /sessions has rate limiting configured" do
    # F-04/login-throttle: brute-force/password-spraying mitigation
    throttles = Rack::Attack.throttles.keys
    assert_includes throttles, "sessions/create", "Web session login should have rate limiting"
  end

  test "API OTP login has per-user rate limiting configured" do
    # F-06: mirror web MFA (5 attempts / 5 min) for API login OTP submissions
    throttles = Rack::Attack.throttles.keys
    assert_includes throttles, "api/otp_attempts/email", "API OTP login should have per-user rate limiting"
  end

  # Behavioral tests — enable Rack::Attack just for these cases (it's disabled
  # in the test env by default). `ensure` blocks restore global state so
  # downstream tests aren't affected.

  test "POST /sessions throttles after session limit from the same IP" do
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    limit = ENV.fetch("RACK_ATTACK_SESSION_LIMIT", 10).to_i

    limit.times do |i|
      post sessions_path,
        params: { email: "throttle-test-#{i}@example.com", password: "wrong" },
        headers: { "REMOTE_ADDR" => "10.0.0.77" }
      assert_not_equal 429, response.status, "request #{i + 1} should not be throttled"
    end

    post sessions_path,
      params: { email: "throttle-test-final@example.com", password: "wrong" },
      headers: { "REMOTE_ADDR" => "10.0.0.77" }

    assert_response :too_many_requests
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
  end

  test "POST /api/v1/auth/login throttles OTP attempts per email for JSON bodies" do
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    limit = ENV.fetch("RACK_ATTACK_OTP_LIMIT", 5).to_i

    payload = { email: "otp-throttle@example.com", password: "wrong", otp_code: "000000" }

    limit.times do |i|
      post "/api/v1/auth/login",
        params: payload.to_json,
        headers: { "CONTENT_TYPE" => "application/json" }
      assert_not_equal 429, response.status, "JSON OTP request #{i + 1} should not be throttled"
    end

    post "/api/v1/auth/login",
      params: payload.to_json,
      headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :too_many_requests,
      "OTP throttle should count JSON-body submissions (mobile clients)"
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
  end
end
