require "test_helper"

class RemoteUserHeaderAuthenticationTest < ActionDispatch::IntegrationTest
  HEADER_NAME = "Remote-Email"
  JIT_EMAIL = "headerjit@test.example"

  setup do
    Rails.application.config.stubs(:remote_user_header_email).returns(HEADER_NAME)
    Rails.application.config.stubs(:remote_user_trusted_proxies).returns(nil)
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

  test "writes SsoAuditLog: jit_account_created once, login on every header-driven session" do
    assert_difference -> { SsoAuditLog.count }, 2 do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end

    user = User.find_by!(email: JIT_EMAIL)

    reset! # drop cookies so the next request goes through the header path again

    assert_difference -> { SsoAuditLog.count }, 1 do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
    end

    events = SsoAuditLog.where(user: user).order(:created_at).pluck(:event_type, :provider)
    assert_equal [
      [ "jit_account_created", "remote_user_header" ],
      [ "login",               "remote_user_header" ],
      [ "login",               "remote_user_header" ]
    ], events
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
                            .returns([ IPAddr.new("127.0.0.0/8") ])

    assert_difference -> { User.count }, 1 do
      get root_url, headers: { HEADER_NAME => JIT_EMAIL }
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
end
