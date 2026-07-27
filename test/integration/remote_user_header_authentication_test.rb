require "test_helper"

class RemoteUserHeaderAuthenticationTest < ActionDispatch::IntegrationTest
  HEADER_NAME = "Remote-Email"
  JIT_EMAIL = "headerjit@test.example"

  setup do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    Rails.application.config.stubs(:remote_user_header_email).returns(HEADER_NAME)
    # Use the production default (loopback) so the integration test client's
    # default REMOTE_ADDR of 127.0.0.1 satisfies the IP gate. Tests that want
    # to exercise the gate explicitly override this.
    Rails.application.config.stubs(:remote_user_trusted_proxies)
                            .returns([ IPAddr.new("127.0.0.0/8"), IPAddr.new("::1/128") ])
  end

  test "feature is inert in managed mode even with config set" do
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(false)

    assert_no_difference -> { User.count } do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end
    assert_redirected_to new_session_url
  end

  test "feature is opt-in: with config unset, the header is ignored" do
    Rails.application.config.stubs(:remote_user_header_email).returns(nil)

    assert_no_difference -> { User.count } do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end
    assert_redirected_to new_session_url
  end

  test "JIT user has password_digest = nil and a created family" do
    get root_url, headers: { HEADER_NAME => JIT_EMAIL }

    user = User.find_by(email: JIT_EMAIL)
    assert_not_nil user, "JIT user should be created"
    assert_nil user.password_digest, "JIT users must not have a local password"
    assert_not_nil user.family, "JIT users must have an associated family"
  end

  test "JIT delegates role assignment to User.role_for_new_family_creator" do
    User.expects(:role_for_new_family_creator)
        .with(fallback_role: :admin)
        .returns(:super_admin)

    get root_url, headers: { HEADER_NAME => JIT_EMAIL }

    assert_equal "super_admin", User.find_by!(email: JIT_EMAIL).role
  end

  test "writes SsoAuditLog: jit_account_created once, login once per distinct client" do
    assert_difference -> { SsoAuditLog.count }, 2 do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end

    user = User.find_by!(email: JIT_EMAIL)

    reset! # drop cookies so the next request goes through the header path again

    # Same IP and user agent, so this is the same client coming back without its
    # cookie: it gets the existing session rather than minting another one, and
    # no second login is recorded.
    assert_no_difference [ -> { SsoAuditLog.count }, -> { user.sessions.count } ] do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end

    reset!

    # A different user agent is a different client, so it does get its own.
    assert_difference [ -> { SsoAuditLog.count }, -> { user.sessions.count } ], 1 do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL, "User-Agent" => "curl/8.7.1" }
    end

    events = SsoAuditLog.where(user: user).order(:created_at).pluck(:event_type, :provider)
    assert_equal [
      [ "jit_account_created", "remote_user_header" ],
      [ "login",               "remote_user_header" ],
      [ "login",               "remote_user_header" ]
    ], events
  end

  test "repeated cookieless requests reuse one session instead of one per request" do
    get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    user = User.find_by!(email: JIT_EMAIL)
    assert_equal 1, user.sessions.count

    5.times do
      reset!
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end

    assert_equal 1, user.sessions.count, "cookieless clients must not mint a Session per request"
  end

  test "cookie session for a different user is invalidated when the header asserts another identity" do
    user_a = users(:family_admin)
    sign_in(user_a)
    cookie_session = user_a.sessions.order(:created_at).last
    assert_not_nil cookie_session, "sign_in should have created a session"

    get root_url, headers: { HEADER_NAME => JIT_EMAIL }

    refute Session.exists?(id: cookie_session.id), "cookie session should be destroyed when header asserts a different user"
    assert_not_nil User.find_by(email: JIT_EMAIL), "header-asserted user should be JIT'd"
  end

  test "IP allowlist: request from a non-allowlisted IP is ignored" do
    Rails.application.config.stubs(:remote_user_trusted_proxies)
                            .returns([ IPAddr.new("10.0.0.0/24") ])

    assert_no_difference -> { User.count } do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end
    assert_redirected_to new_session_url
  end

  test "IP allowlist: request from an allowlisted CIDR is honored" do
    Rails.application.config.stubs(:remote_user_trusted_proxies)
                            .returns([ IPAddr.new("10.0.0.0/24") ])

    assert_difference -> { User.count }, 1 do
      get root_url,
          env: { "REMOTE_ADDR" => "10.0.0.5" },
          headers: { HEADER_NAME => JIT_EMAIL }
    end
  end

  test "default loopback allowlist honors a request from 127.0.0.1" do
    # Setup mirrors the production loopback default (127.0.0.0/8 + ::1/128)
    # and the integration client connects from 127.0.0.1, so JIT proceeds.
    assert_difference -> { User.count }, 1 do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end
  end

  test "shared secret: when configured, request without the secret header is ignored" do
    Rails.application.config.stubs(:remote_user_shared_secret).returns("s3cr3t")
    Rails.application.config.stubs(:remote_user_shared_secret_header).returns("X-Remote-User-Secret")

    assert_no_difference -> { User.count } do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end
    assert_redirected_to new_session_url
  end

  test "shared secret: when configured, mismatched secret is ignored" do
    Rails.application.config.stubs(:remote_user_shared_secret).returns("s3cr3t")
    Rails.application.config.stubs(:remote_user_shared_secret_header).returns("X-Remote-User-Secret")

    assert_no_difference -> { User.count } do
      get root_url, headers: {
        HEADER_NAME => JIT_EMAIL,
        "X-Remote-User-Secret" => "wrong"
      }
    end
    assert_redirected_to new_session_url
  end

  test "shared secret: matching secret allows the request through" do
    Rails.application.config.stubs(:remote_user_shared_secret).returns("s3cr3t")
    Rails.application.config.stubs(:remote_user_shared_secret_header).returns("X-Remote-User-Secret")

    assert_difference -> { User.count }, 1 do
      get root_url, headers: {
        HEADER_NAME => JIT_EMAIL,
        "X-Remote-User-Secret" => "s3cr3t"
      }
    end
  end

  test "malformed email value fails closed without raising" do
    [ "not an email", "", "  ", "@", "foo@" ].each do |bad|
      assert_no_difference -> { User.count }, "header value #{bad.inspect} should not JIT" do
        get root_url, headers: { HEADER_NAME => bad }
      end
      assert_redirected_to new_session_url
    end
  end

  test "unparseable REMOTE_ADDR fails closed" do
    assert_no_difference -> { User.count } do
      get root_url, env: { "REMOTE_ADDR" => "not-an-ip" }, headers: { HEADER_NAME => JIT_EMAIL }
    end
    assert_redirected_to new_session_url
  end

  test "IPv4-mapped IPv6 peer satisfies the loopback default" do
    # ::ffff:127.0.0.1 is what a dual-stack front-end commonly produces, and
    # IPAddr#include? doesn't cross address families, so it has to be normalized.
    assert_difference -> { User.count }, 1 do
      get root_url,
          env: { "REMOTE_ADDR" => "::ffff:127.0.0.1" },
          headers: { HEADER_NAME => JIT_EMAIL }
    end
  end

  test "an existing local-password account is logged in by the header, credentials untouched" do
    user = users(:family_admin)
    assert user.has_local_password?, "fixture should have a local password"
    digest_before = user.password_digest

    assert_difference -> { user.sessions.count }, 1 do
      get root_url, headers: { HEADER_NAME => user.email }
    end

    assert_equal digest_before, user.reload.password_digest, "header login must not alter local credentials"
    assert_equal [ "login" ], SsoAuditLog.where(user: user).pluck(:event_type)
  end

  test "MFA is not enforced on the header path: the proxy owns the second factor" do
    # Documented behavior, not an oversight — see the "Reverse-proxy
    # authentication" section of docs/hosting/docker.md. There is no local
    # password to fall back on here, so the header path cannot challenge.
    user = users(:family_admin)
    user.update!(otp_secret: ROTP::Base32.random(32), otp_required: true)

    assert_difference -> { user.sessions.count }, 1 do
      get root_url, headers: { HEADER_NAME => user.email }
    end

    refute_equal verify_mfa_url, response.location
  end

  test "pending invitation is honored: invitee joins the inviting family" do
    invitation = invitations(:one)
    assert invitation.pending?

    assert_no_difference -> { Family.count } do
      assert_difference -> { User.count }, 1 do
        get root_url, headers: { HEADER_NAME => invitation.email }
      end
    end

    user = User.find_by!(email: invitation.email)
    assert_equal invitation.family_id, user.family_id, "invitee must join the family they were invited to"
    assert_equal invitation.role, user.role
    assert_not_nil invitation.reload.accepted_at, "invitation should be marked accepted"
  end

  test "a pending invitation overrides a restrictive JIT policy" do
    Rails.application.config.stubs(:remote_user_allow_jit).returns(false)
    invitation = invitations(:one)

    assert_difference -> { User.count }, 1 do
      get root_url, headers: { HEADER_NAME => invitation.email }
    end

    assert_equal invitation.family_id, User.find_by!(email: invitation.email).family_id
  end

  test "REMOTE_USER_ALLOW_JIT=false blocks creation but still logs in existing accounts" do
    Rails.application.config.stubs(:remote_user_allow_jit).returns(false)

    assert_no_difference -> { User.count } do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end
    assert_redirected_to new_session_url

    reset!
    user = users(:family_admin)
    assert_difference -> { user.sessions.count }, 1 do
      get root_url, headers: { HEADER_NAME => user.email }
    end
  end

  test "AUTH_JIT_MODE=link_only blocks header account creation" do
    AuthConfig.stubs(:jit_link_only?).returns(true)

    assert_no_difference -> { User.count } do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end
    assert_redirected_to new_session_url
  end

  test "a domain outside ALLOWED_OIDC_DOMAINS cannot be created by the header" do
    AuthConfig.stubs(:allowed_oidc_domain?).returns(false)

    assert_no_difference -> { User.count } do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end
    assert_redirected_to new_session_url
  end

  test "a deactivated account is refused rather than logged in" do
    user = users(:family_member)
    # update_column so the email isn't mangled, which is the only way an
    # inactive row is reachable by an exact-email lookup.
    user.update_column(:active, false)

    assert_no_difference -> { User.count } do
      get root_url, headers: { HEADER_NAME => user.email }
    end
    assert_redirected_to new_session_url
  end

  test "REMOTE_USER_ALLOW_JIT=false keeps a deactivated email from re-entering" do
    # User#deactivate mangles the email, so the lookup can't see the row at all
    # and the account would otherwise be JIT-created fresh. Revocation has to be
    # enforced by disabling creation (and at the proxy).
    Rails.application.config.stubs(:remote_user_allow_jit).returns(false)
    user = users(:family_member)
    original_email = user.email
    assert user.deactivate

    assert_no_difference -> { User.count } do
      get root_url, headers: { HEADER_NAME => original_email }
    end
    assert_redirected_to new_session_url
  end

  test "a User validation failure fails closed instead of 500ing out of the before_action" do
    User.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(User.new))

    assert_no_difference -> { User.count } do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end
    assert_redirected_to new_session_url
  end

  test "losing the unique-index race resolves to the row that won it" do
    existing = users(:family_admin)
    # The lookup misses because the concurrent request hasn't committed yet, then
    # our INSERT loses the race on the unique email index.
    User.stubs(:find_by).returns(nil).then.returns(existing)
    User.any_instance.stubs(:save!).raises(ActiveRecord::RecordNotUnique.new("duplicate key"))

    assert_no_difference -> { User.count } do
      assert_difference -> { existing.sessions.count }, 1 do
        get root_url, headers: { HEADER_NAME => existing.email }
      end
    end
  end

  test "logout redirects to the proxy sign-out URL when one is configured" do
    Rails.application.config.stubs(:remote_user_logout_url).returns("https://auth.example.test/logout")
    user = users(:family_admin)

    get root_url, headers: { HEADER_NAME => user.email }
    session_record = user.sessions.order(:created_at).last
    assert_not_nil session_record

    delete session_path(session_record)

    assert_redirected_to "https://auth.example.test/logout"
    refute Session.exists?(id: session_record.id)
  end

  test "logout falls back to the login page with no proxy sign-out URL, and the header signs back in" do
    Rails.application.config.stubs(:remote_user_logout_url).returns(nil)
    user = users(:family_admin)

    get root_url, headers: { HEADER_NAME => user.email }
    session_record = user.sessions.order(:created_at).last

    delete session_path(session_record)
    assert_redirected_to new_session_path
    refute Session.exists?(id: session_record.id)

    # Without a proxy sign-out, the header is still on the next request. This is
    # why REMOTE_USER_LOGOUT_URL exists.
    assert_difference -> { user.sessions.count }, 1 do
      get root_url, headers: { HEADER_NAME => user.email }
    end
  end
end
