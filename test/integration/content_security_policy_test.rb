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

  test "allows every Plaid API host whatever environment PLAID_ENV names" do
    # The effective Plaid environment can come from Settings > Providers or
    # PLAID_EU_ENV, so the policy must not depend on PLAID_ENV alone.
    get new_session_url

    connect_src = csp_directive("connect-src")
    %w[sandbox development production].each do |env|
      assert_includes connect_src, "https://#{env}.plaid.com"
    end
    assert_includes csp_directive("script-src"), "https://cdn.plaid.com"
    assert_includes csp_directive("frame-src"), "https://cdn.plaid.com"
  end

  test "allows the self-hosted feedback survey's PostHog hosts without POSTHOG_KEY" do
    user = users(:family_admin)
    user.update!(preferences: user.preferences.merge("preview_features_enabled" => true))
    sign_in user
    config = Rails.configuration.x.posthog
    config.stubs(:api_key).returns(nil)
    config.stubs(:feedback_enabled).returns(true)
    config.stubs(:development_enabled).returns(false)
    Rails.env.stubs(:production?).returns(true)

    with_self_hosting do
      get root_path
      assert_select "#cashflow-preview[data-sankey-preview-feedback-host-value='https://us.i.posthog.com']"
      [ "script-src", "connect-src" ].each do |directive|
        assert_includes csp_directive(directive), "https://us.i.posthog.com"
        assert_includes csp_directive(directive), "https://us-assets.i.posthog.com"
      end

      config.stubs(:feedback_enabled).returns(false)
      get root_path
      assert_select "#cashflow-preview[data-sankey-preview-feedback-host-value='']"
      assert_not_includes response.headers["Content-Security-Policy"], "posthog.com"
    end
  end

  test "allows the analytics PostHog host only when analytics are enabled" do
    config = Rails.configuration.x.posthog
    config.stubs(:feedback_enabled).returns(false)
    config.stubs(:host).returns("https://eu.i.posthog.com")
    Rails.env.stubs(:production?).returns(true)

    config.stubs(:api_key).returns(nil)
    get new_session_url
    assert_not_includes response.headers["Content-Security-Policy"], "posthog.com"

    config.stubs(:api_key).returns("operator-owned-project")
    get new_session_url
    [ "script-src", "connect-src" ].each do |directive|
      assert_includes csp_directive(directive), "https://eu.i.posthog.com"
      assert_includes csp_directive(directive), "https://eu-assets.i.posthog.com"
    end
  end

  test "adds no PostHog hosts outside production unless development opts in" do
    config = Rails.configuration.x.posthog
    config.stubs(:api_key).returns("operator-owned-project")
    config.stubs(:feedback_enabled).returns(true)
    config.stubs(:development_enabled).returns(false)

    with_self_hosting do
      get new_session_url
      assert_not_includes response.headers["Content-Security-Policy"], "posthog.com"
    end
  end

  test "sends a restrictive Permissions-Policy header" do
    get new_session_url

    policy = response.headers["Feature-Policy"] || response.headers["Permissions-Policy"]
    assert policy.present?, "Permissions-Policy header must be set"
    assert_includes policy, "camera 'none'"
    assert_includes policy, "microphone 'none'"
  end

  private
    def csp_directive(name)
      response.headers["Content-Security-Policy"][/#{name} ([^;]+)/, 1].to_s.split
    end
end
