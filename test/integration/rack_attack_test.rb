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
      password_change/ip password_change/user
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

  test "password change throttles discriminate by ip and signed-in user, and ignore unrelated requests" do
    ip_block = Rack::Attack.throttles["password_change/ip"].block
    user_block = Rack::Attack.throttles["password_change/user"].block

    admin = users(:family_admin)
    first_session = admin.sessions.create!
    second_session = admin.sessions.create!
    other_session = users(:family_member).sessions.create!
    user_key = "user:#{admin.id}"

    %w[PATCH PUT].each do |method|
      request = throttle_request("/password", method: method, session_cookie: first_session.id)
      assert_equal "203.0.113.5", ip_block.call(request), "#{method} /password should count toward the ip throttle"
      assert_equal user_key, user_block.call(request), "#{method} /password should count toward the user throttle"
    end

    second_session_request = throttle_request("/password", method: "PATCH", session_cookie: second_session.id)
    assert_equal user_key, user_block.call(second_session_request), "all of a user's sessions share one budget"

    other_user_request = throttle_request("/password", method: "PATCH", session_cookie: other_session.id)
    assert_equal "user:#{users(:family_member).id}", user_block.call(other_user_request), "each user gets their own budget"

    format_request = throttle_request("/password.json", method: "PATCH", session_cookie: first_session.id)
    assert_equal user_key, user_block.call(format_request)

    # No route accepts POST /password; the form's POST + `_method=patch` is
    # rewritten to PATCH by Rack::MethodOverride before Rack::Attack runs.
    post_request = throttle_request("/password", method: "POST", session_cookie: first_session.id)
    assert_nil ip_block.call(post_request)

    edit_request = throttle_request("/password/edit", method: "GET", session_cookie: first_session.id)
    assert_nil ip_block.call(edit_request), "viewing the form must not count toward the throttle"
    assert_nil user_block.call(edit_request)

    reset_request = throttle_request("/password_reset", method: "POST", session_cookie: first_session.id)
    assert_nil ip_block.call(reset_request)
    assert_nil user_block.call(reset_request)

    # Without a valid session the request is redirected to sign in before any
    # password check, so it spends neither budget.
    no_session_request = throttle_request("/password", method: "PATCH")
    assert_nil user_block.call(no_session_request), "a missing session cookie must not produce a throttle key"
    assert_nil ip_block.call(no_session_request), "a missing session cookie must not spend the ip budget"

    tampered_request = throttle_request("/password", method: "PATCH", raw_cookie: "session_token=#{first_session.id}")
    assert_nil user_block.call(tampered_request), "an unsigned session cookie must not produce a throttle key"
    assert_nil ip_block.call(tampered_request), "an unsigned session cookie must not spend the ip budget"

    unknown_session_request = throttle_request("/password", method: "PATCH", session_cookie: SecureRandom.uuid)
    assert_nil user_block.call(unknown_session_request), "a session that no longer exists must not produce a throttle key"
    assert_nil ip_block.call(unknown_session_request), "a session that no longer exists must not spend the ip budget"
  end

  test "password change throttles ignore a session whose user was deactivated" do
    ip_block = Rack::Attack.throttles["password_change/ip"].block
    user_block = Rack::Attack.throttles["password_change/user"].block
    user = users(:family_member)
    session = user.sessions.create!
    user.update_column(:active, false)

    request = throttle_request("/password", method: "PATCH", session_cookie: session.id)
    assert_nil user_block.call(request), "authentication rejects this session, so it must not produce a user key"
    assert_nil ip_block.call(request), "authentication rejects this session, so it must not spend the ip budget"
  end

  test "password change throttle keys an impersonation by the impersonated user" do
    user_block = Rack::Attack.throttles["password_change/user"].block
    impersonation = impersonation_sessions(:in_progress)
    support_session = users(:sure_support_staff).sessions.create!(active_impersonator_session: impersonation)

    request = throttle_request("/password", method: "PATCH", session_cookie: support_session.id)
    assert_equal "user:#{users(:family_member).id}", user_block.call(request),
      "the password being checked is the impersonated user's, like Current.user"

    impersonation.complete!
    request = throttle_request("/password", method: "PATCH", session_cookie: support_session.id)
    assert_equal "user:#{users(:sure_support_staff).id}", user_block.call(request),
      "once the impersonation ends the session owner is the user again"
  end

  test "password change throttle blocks a signed-in session that rotates ips" do
    # End to end through the real middleware stack: proves the session cookie
    # is readable from inside Rack::Attack, which runs after MethodOverride
    # but before the controller. The new password is deliberately too short so
    # no request changes it; the throttle counts attempts, not failures.
    sign_in users(:family_admin)

    # Rack::Attack counts in fixed one-minute windows; freeze the clock so a
    # minute boundary can't reset the counter mid-test.
    freeze_time

    with_rack_attack_enabled do
      10.times do |i|
        patch password_path, params: { user: { password_challenge: "wrong", password: "short", password_confirmation: "short" } },
          env: { "REMOTE_ADDR" => "198.51.100.#{i + 1}" }
        assert_response :unprocessable_entity
      end

      patch password_path, params: { user: { password_challenge: "wrong", password: "short", password_confirmation: "short" } },
        env: { "REMOTE_ADDR" => "198.51.100.99" }
      assert_response :too_many_requests
    end
  end

  test "password change throttle shares one budget across a user's sessions" do
    # Two separate browser sessions of the same user, each on its own ip:
    # a per-session budget would allow 10 guesses per stolen session.
    first = open_session
    second = open_session
    [ first, second ].each do |browser|
      browser.post sessions_path, params: { email: users(:family_admin).email, password: user_password_test }
    end

    freeze_time

    params = { user: { password_challenge: "wrong", password: "short", password_confirmation: "short" } }

    with_rack_attack_enabled do
      5.times do |i|
        first.patch password_path, params: params, env: { "REMOTE_ADDR" => "198.51.100.#{i + 1}" }
        assert_equal 422, first.response.status
        second.patch password_path, params: params, env: { "REMOTE_ADDR" => "198.51.100.#{i + 101}" }
        assert_equal 422, second.response.status
      end

      second.patch password_path, params: params, env: { "REMOTE_ADDR" => "198.51.100.250" }
      assert_equal 429, second.response.status
    end
  end

  test "credential-guessing throttles still match when the path carries a format extension" do
    # None of these routes are declared `format: false`, so Rails' default
    # `(.:format)` segment means e.g. "/sessions.json" still reaches
    # SessionsController#create even though request.path for that request is
    # "/sessions.json", not "/sessions". A throttle keyed on exact string
    # equality would silently let a scripted attacker brute-force every
    # credential-guessing endpoint unthrottled just by appending an
    # extension.
    ip_block = Rack::Attack.throttles["logins/ip"].block
    email_block = Rack::Attack.throttles["logins/email"].block

    request = throttle_request("/sessions.json", method: "POST", params: { "email" => "user@example.com" })
    assert_equal "203.0.113.5", ip_block.call(request)
    assert_equal "user@example.com", email_block.call(request)

    api_login_block = Rack::Attack.throttles["api_login/ip"].block
    api_login_request = throttle_request("/api/v1/auth/login.json", method: "POST")
    assert_equal "203.0.113.5", api_login_block.call(api_login_request)

    # Rails' actual default segment matcher for `(.:format)` is `[^./?]+`,
    # not `\w+` — it permits hyphens (and other punctuation), so a format
    # value like "rate-limit" is a real route match, not just a hypothetical.
    hyphenated_format_request = throttle_request("/api/v1/auth/login.rate-limit", method: "POST")
    assert_equal "203.0.113.5", api_login_block.call(hyphenated_format_request)

    # A path that merely starts with the throttled path, without being a
    # format suffix, must still be ignored.
    unrelated_request = throttle_request("/sessions_other", method: "POST", params: { "email" => "user@example.com" })
    assert_nil ip_block.call(unrelated_request)
  end

  test "json email extraction tolerates non-object JSON payloads without raising" do
    api_login_email_block = Rack::Attack.throttles["api_login/email"].block

    null_request = throttle_request("/api/v1/auth/login", method: "POST", json_body_raw: "null")
    assert_nil api_login_email_block.call(null_request)

    array_request = throttle_request("/api/v1/auth/login", method: "POST", json_body_raw: "[1,2,3]")
    assert_nil api_login_email_block.call(array_request)
  end

  test "json email extraction skips a non-rewindable rack.input instead of raising or consuming the body" do
    # Rack 3 no longer requires rack.input to be rewindable (streaming
    # servers may not buffer it) — simulate that by using an input object
    # that only implements #read, not #rewind.
    api_login_email_block = Rack::Attack.throttles["api_login/email"].block

    request = throttle_request("/api/v1/auth/login", method: "POST", non_rewindable_json_body: { email: "user@example.com" })
    assert_nil api_login_email_block.call(request)

    # A block that read the body and then just returned nil (e.g. on a
    # parse error) would also pass the assertion above while leaving the
    # controller with an exhausted stream — assert the body was never
    # touched at all.
    assert_equal({ "email" => "user@example.com" }, JSON.parse(request.body.read))
  end

  private

    # Rack::Attack is disabled in the test environment and its counters live
    # in Rails.cache (:null_store here), so give it a real store for the block.
    def with_rack_attack_enabled
      previous_enabled = Rack::Attack.enabled
      previous_store = Rack::Attack.cache.store
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      Rack::Attack.enabled = true
      yield
    ensure
      Rack::Attack.enabled = previous_enabled
      Rack::Attack.cache.store = previous_store
    end

    def signed_session_cookie(value)
      jar = ActionDispatch::Request.new(Rails.application.env_config.dup).cookie_jar
      jar.signed[:session_token] = value
      "session_token=#{Rack::Utils.escape(jar[:session_token])}"
    end

    NonRewindableInput = Struct.new(:io) do
      def read(*args) = io.read(*args)
    end

    def throttle_request(path, method: "GET", params: {}, session: {}, json_body: nil, json_body_raw: nil, non_rewindable_json_body: nil, session_cookie: nil, raw_cookie: nil)
      # Rack::MockRequest.env_for doesn't set REMOTE_ADDR, so #ip is nil
      # unless set explicitly — asserting against a real value here (rather
      # than comparing to request.ip, which could trivially be nil on both
      # sides) is what actually proves the ip-based discriminator extracts
      # something.
      opts = { method: method, params: params, "REMOTE_ADDR" => "203.0.113.5" }

      if json_body || json_body_raw
        opts[:input] = json_body_raw || json_body.to_json
        opts["CONTENT_TYPE"] = "application/json"
      elsif non_rewindable_json_body
        opts[:input] = NonRewindableInput.new(StringIO.new(non_rewindable_json_body.to_json))
        opts["CONTENT_TYPE"] = "application/json"
      end

      opts["HTTP_COOKIE"] = raw_cookie || signed_session_cookie(session_cookie) if raw_cookie || session_cookie

      # Rails merges env_config (the cookie key generator, among others) into
      # every request env before the middleware stack runs, Rack::Attack
      # included.
      env = Rails.application.env_config.merge(Rack::MockRequest.env_for(path, opts))
      env["rack.session"] = session
      Rack::Attack::Request.new(env)
    end
end
