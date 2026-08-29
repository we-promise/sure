# frozen_string_literal: true

require "test_helper"

class RackAttackTest < ActionDispatch::IntegrationTest
  test "rack attack is configured" do
    # Verify Rack::Attack is enabled in middleware stack
    middleware_classes = Rails.application.middleware.map(&:klass)
    assert_includes middleware_classes, Rack::Attack, "Rack::Attack should be in middleware stack"
  end

  test "rack attack is only inserted into the middleware stack once" do
    # Regression guard: Rack::Attack's own Railtie already inserts it, and
    # config/application.rb previously also called config.middleware.use
    # Rack::Attack explicitly — the counters incremented twice per request,
    # so every throttle limit fired at half its documented value.
    middleware_classes = Rails.application.middleware.map(&:klass)
    assert_equal 1, middleware_classes.count(Rack::Attack)
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

  test "credential-guessing surfaces have rate limiting configured" do
    throttles = Rack::Attack.throttles.keys
    %w[
      logins/ip logins/email
      mfa/verify/ip mfa/verify/user
      password_resets/ip password_resets/email
      oidc_account_link/ip oidc_account_link/email
      api_login/ip api_login/email
      api_sso_link/ip api_sso_link/email
    ].each do |name|
      assert_includes throttles, name, "#{name} should have rate limiting configured"
    end
  end

  # Rack::Attack's counters rely on Rails.cache, which is :null_store in the
  # test environment (config/environments/test.rb) — a throttle can never
  # actually fire here regardless of request volume, which is why the tests
  # above only check registration. To still verify the matching logic itself
  # (right path, right discriminator, blank-input handling), call each
  # throttle's block directly against a constructed request instead of
  # sending real requests through the stack.
  test "login throttles discriminate by ip and normalized email, and ignore unrelated requests" do
    ip_block = Rack::Attack.throttles["logins/ip"].block
    email_block = Rack::Attack.throttles["logins/email"].block

    login_request = throttle_request("/sessions", method: "POST", params: { "email" => " User@Example.com " })
    assert_equal "203.0.113.5", ip_block.call(login_request)
    assert_equal "user@example.com", email_block.call(login_request)

    get_request = throttle_request("/sessions", method: "GET")
    assert_nil ip_block.call(get_request), "GET requests must not count toward the throttle"

    unrelated_path_request = throttle_request("/mfa/verify", method: "POST", params: { "email" => "x@example.com" })
    assert_nil ip_block.call(unrelated_path_request)

    blank_email_request = throttle_request("/sessions", method: "POST", params: {})
    assert_nil email_block.call(blank_email_request), "a missing email must not produce a throttle key"
  end

  test "mfa verify throttle discriminates by the pending session user id, not email" do
    ip_block = Rack::Attack.throttles["mfa/verify/ip"].block
    user_block = Rack::Attack.throttles["mfa/verify/user"].block

    request = throttle_request("/mfa/verify", method: "POST", session: { mfa_user_id: "abc-123" })
    assert_equal "203.0.113.5", ip_block.call(request)
    assert_equal "abc-123", user_block.call(request)

    no_session_request = throttle_request("/mfa/verify", method: "POST")
    assert_nil user_block.call(no_session_request)
  end

  test "api login and sso-link throttles match their own paths only" do
    api_login_block = Rack::Attack.throttles["api_login/ip"].block
    sso_link_block = Rack::Attack.throttles["api_sso_link/ip"].block

    api_login_request = throttle_request("/api/v1/auth/login", method: "POST")
    assert_equal "203.0.113.5", api_login_block.call(api_login_request)
    assert_nil sso_link_block.call(api_login_request)

    sso_link_request = throttle_request("/api/v1/auth/sso_link", method: "POST")
    assert_equal "203.0.113.5", sso_link_block.call(sso_link_request)
    assert_nil api_login_block.call(sso_link_request)
  end

  test "api login and sso-link email throttles discriminate JSON bodies, the documented mobile format" do
    api_login_email_block = Rack::Attack.throttles["api_login/email"].block
    api_sso_link_email_block = Rack::Attack.throttles["api_sso_link/email"].block

    api_login_request = throttle_request("/api/v1/auth/login", method: "POST",
      json_body: { email: " User@Example.com ", password: "secret" })
    assert_equal "user@example.com", api_login_email_block.call(api_login_request)

    sso_link_request = throttle_request("/api/v1/auth/sso_link", method: "POST",
      json_body: { email: " User@Example.com ", password: "secret" })
    assert_equal "user@example.com", api_sso_link_email_block.call(sso_link_request)

    # The controller must still be able to read the body after Rack::Attack
    # inspected it — this is what proves the peek rewinds rather than
    # consuming the input stream.
    assert_equal({ "email" => " User@Example.com ", "password" => "secret" }, JSON.parse(api_login_request.body.read))

    malformed_request = throttle_request("/api/v1/auth/login", method: "POST", json_body_raw: "not json")
    assert_nil api_login_email_block.call(malformed_request)
  end

  private

    def throttle_request(path, method: "GET", params: {}, session: {}, json_body: nil, json_body_raw: nil)
      # Rack::MockRequest.env_for doesn't set REMOTE_ADDR, so #ip is nil
      # unless set explicitly — asserting against a real value here (rather
      # than comparing to request.ip, which could trivially be nil on both
      # sides) is what actually proves the ip-based discriminator extracts
      # something.
      opts = { method: method, params: params, "REMOTE_ADDR" => "203.0.113.5" }

      if json_body || json_body_raw
        opts[:input] = json_body_raw || json_body.to_json
        opts["CONTENT_TYPE"] = "application/json"
      end

      env = Rack::MockRequest.env_for(path, opts)
      env["rack.session"] = session
      Rack::Attack::Request.new(env)
    end
end
