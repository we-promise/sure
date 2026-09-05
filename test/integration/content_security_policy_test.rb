require "test_helper"

class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  test "sends a nonce-based CSP header that forbids unsafe-inline scripts" do
    get new_session_url

    csp = response.headers["Content-Security-Policy"]
    assert csp.present?, "Content-Security-Policy header must be set"

    script_src = csp[/script-src ([^;]+)/, 1]
    assert_includes script_src, "'self'"
    assert_match(/'nonce-[0-9a-f]+'/, script_src)
    assert_not_includes script_src, "'unsafe-inline'", "script-src must never allow unsafe-inline"
    assert_not_includes script_src, "'unsafe-eval'", "script-src must never allow unsafe-eval"

    assert_includes csp, "object-src 'none'"
    assert_includes csp, "base-uri 'self'"
    assert_includes csp, "frame-ancestors 'self'"
  end

  test "the CSP nonce sent in the header matches the nonce rendered on inline scripts" do
    get new_session_url

    csp = response.headers["Content-Security-Policy"]
    nonce = csp[/'nonce-([0-9a-f]+)'/, 1]
    assert nonce.present?

    inline_scripts = assert_select "script:not([src])"
    assert_select "script:not([src])[nonce=?]", nonce, count: inline_scripts.size
  end

  test "sends a restrictive Permissions-Policy header" do
    get new_session_url

    policy = response.headers["Feature-Policy"] || response.headers["Permissions-Policy"]
    assert policy.present?, "Permissions-Policy header must be set"
    assert_includes policy, "camera 'none'"
    assert_includes policy, "microphone 'none'"
  end
end
