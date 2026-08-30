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

  test "remote user header has rate limiting configured" do
    throttles = Rack::Attack.throttles.keys
    assert_includes throttles, "remote-user-header/email", "Remote user header should have rate limiting"
  end

  # Rack::Attack itself is disabled outside production, so exercise the
  # discriminator directly. A forward-auth proxy stamps the header on every
  # request, and counting the ones that can't mint a session would throttle
  # ordinary browsing.
  test "remote user header throttle counts only cookieless requests to the UI" do
    Rails.application.config.stubs(:remote_user_header_email).returns("Remote-Email")
    discriminator = Rack::Attack.throttles["remote-user-header/email"].block

    assert_equal "user@example.com", discriminator.call(header_request("/"))
    assert_equal "user@example.com", discriminator.call(header_request("/", email: "  User@Example.com  "))

    # Any session_token scopes the request out, verified or not. This throttle
    # runs as middleware, before authenticate_user! has read the cookie, so
    # deciding whether the session is real here would cost a Session lookup on
    # every request and hand any peer that reaches the port a database query it
    # can drive. Cookie presence is a scope discriminator, not a boundary.
    assert_nil discriminator.call(header_request("/", cookie: "session_token=abc")),
      "an unverified session_token still scopes the request out of the throttle"
    assert_nil discriminator.call(header_request("/api/v1/accounts"))
    assert_nil discriminator.call(header_request("/mcp"))
    assert_nil discriminator.call(header_request("/", email: ""))
    assert_nil discriminator.call(Rack::Attack::Request.new(Rack::MockRequest.env_for("/")))
  end

  test "remote user header throttle is inert when the header is not configured" do
    Rails.application.config.stubs(:remote_user_header_email).returns(nil)
    discriminator = Rack::Attack.throttles["remote-user-header/email"].block

    assert_nil discriminator.call(header_request("/"))
  end

  test "api requests have rate limiting configured" do
    # Test that API rate limiting is configured
    throttles = Rack::Attack.throttles.keys
    assert_includes throttles, "api/requests", "API requests should have rate limiting"
  end

  private
    def header_request(path, email: "user@example.com", cookie: nil)
      env = Rack::MockRequest.env_for(path, "HTTP_REMOTE_EMAIL" => email)
      env["HTTP_COOKIE"] = cookie if cookie
      Rack::Attack::Request.new(env)
    end
end
