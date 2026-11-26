require "test_helper"

class CorsOriginsTest < ActiveSupport::TestCase
  test "reads a comma-separated list, trimming blanks" do
    with_env_overrides(ALLOWED_ORIGINS: " https://app.example.com , ,https://staging.example.com ") do
      assert_equal [ "https://app.example.com", "https://staging.example.com" ], CorsOrigins.list
    end
  end

  test "falls back to APP_DOMAIN when no explicit list is set" do
    with_env_overrides(ALLOWED_ORIGINS: nil, APP_DOMAIN: "app.example.com") do
      Rails.application.config.stubs(:force_ssl).returns(true)
      assert_equal [ "https://app.example.com" ], CorsOrigins.list
    end
  end

  test "uses http for APP_DOMAIN when the app is not served over SSL" do
    with_env_overrides(ALLOWED_ORIGINS: nil, APP_DOMAIN: "app.example.com") do
      Rails.application.config.stubs(:force_ssl).returns(false)
      Rails.application.config.stubs(:assume_ssl).returns(false)
      assert_equal [ "http://app.example.com" ], CorsOrigins.list
    end
  end

  # A list of junk separators must not become an empty allow-list by accident,
  # nor swallow the APP_DOMAIN fallback.
  test "junk in ALLOWED_ORIGINS falls through to APP_DOMAIN" do
    with_env_overrides(ALLOWED_ORIGINS: " , , ", APP_DOMAIN: "app.example.com") do
      Rails.application.config.stubs(:force_ssl).returns(true)
      assert_equal [ "https://app.example.com" ], CorsOrigins.list
    end
  end

  test "returns nothing when neither variable is set" do
    with_env_overrides(ALLOWED_ORIGINS: nil, APP_DOMAIN: nil) do
      assert_empty CorsOrigins.list
    end
  end

  # These are all things an operator plausibly writes by hand or pastes from a
  # browser. Silently failing to match is worse than accepting them.
  test "normalizes case, trailing slashes, paths and default ports" do
    with_env_overrides(ALLOWED_ORIGINS: "HTTPS://App.Example.com/, https://a.example.com:443, https://b.example.com/path") do
      assert_equal [ "https://app.example.com", "https://a.example.com", "https://b.example.com" ], CorsOrigins.list
    end
  end

  test "keeps a port that is not the default for the scheme" do
    with_env_overrides(ALLOWED_ORIGINS: "http://app.example.com:3000") do
      assert_equal [ "http://app.example.com:3000" ], CorsOrigins.list
    end
  end

  test "drops entries that are not origins at all" do
    with_env_overrides(ALLOWED_ORIGINS: "app.example.com, https://ok.example.com, not a url") do
      assert_equal [ "https://ok.example.com" ], CorsOrigins.list
    end
  end

  test "accepts an APP_DOMAIN that already carries a scheme" do
    with_env_overrides(ALLOWED_ORIGINS: nil, APP_DOMAIN: "https://app.example.com/") do
      assert_equal [ "https://app.example.com" ], CorsOrigins.list
    end
  end

  # Equality, not a prefix: an origin is a scheme, host and port.
  test "allows only an exact match" do
    CorsOrigins.stubs(:list).returns([ "https://app.example.com" ])

    assert CorsOrigins.allowed?("https://app.example.com")
    assert_not CorsOrigins.allowed?("https://app.example.com.evil.test")
    assert_not CorsOrigins.allowed?("https://app.example.com:8443")
    assert_not CorsOrigins.allowed?("null")
    assert_not CorsOrigins.allowed?(nil)
  end

  # `flutter run -d chrome`, documented in mobile/README.md, serves the client
  # from localhost on a port it picks at random, and used to rely on the "*".
  test "allows a loopback origin on any port in development" do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("development"))

    with_env_overrides(ALLOWED_ORIGINS: nil, APP_DOMAIN: nil) do
      assert CorsOrigins.allowed?("http://localhost:52731")
      assert CorsOrigins.allowed?("http://127.0.0.1:8080")
      assert CorsOrigins.allowed?("http://[::1]:8080")
      assert_not CorsOrigins.allowed?("http://evil.example")
      assert_not CorsOrigins.allowed?("http://localhost.evil.example")
      assert_not CorsOrigins.allowed?("file://localhost")
    end
  end

  test "does not allow loopback origins outside development" do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("production"))

    with_env_overrides(ALLOWED_ORIGINS: nil, APP_DOMAIN: nil) do
      assert_not CorsOrigins.allowed?("http://localhost:52731")
    end
  end
end
