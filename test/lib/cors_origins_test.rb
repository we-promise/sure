require "test_helper"

class CorsOriginsTest < ActiveSupport::TestCase
  test "reads a comma-separated list, trimming blanks" do
    with_env("ALLOWED_ORIGINS" => " https://app.example.com , ,https://staging.example.com ") do
      assert_equal [ "https://app.example.com", "https://staging.example.com" ], CorsOrigins.list
    end
  end

  test "falls back to APP_DOMAIN when no explicit list is set" do
    with_env("ALLOWED_ORIGINS" => nil, "APP_DOMAIN" => "app.example.com") do
      Rails.application.config.stubs(:force_ssl).returns(true)
      assert_equal [ "https://app.example.com" ], CorsOrigins.list
    end
  end

  test "uses http for APP_DOMAIN when the app is not served over SSL" do
    with_env("ALLOWED_ORIGINS" => nil, "APP_DOMAIN" => "app.example.com") do
      Rails.application.config.stubs(:force_ssl).returns(false)
      Rails.application.config.stubs(:assume_ssl).returns(false)
      assert_equal [ "http://app.example.com" ], CorsOrigins.list
    end
  end

  # A list of junk separators must not become an empty allow-list by accident,
  # nor swallow the APP_DOMAIN fallback.
  test "junk in ALLOWED_ORIGINS falls through to APP_DOMAIN" do
    with_env("ALLOWED_ORIGINS" => " , , ", "APP_DOMAIN" => "app.example.com") do
      Rails.application.config.stubs(:force_ssl).returns(true)
      assert_equal [ "https://app.example.com" ], CorsOrigins.list
    end
  end

  test "returns nothing when neither variable is set" do
    with_env("ALLOWED_ORIGINS" => nil, "APP_DOMAIN" => nil) do
      assert_empty CorsOrigins.list
    end
  end


  # These are all things an operator plausibly writes by hand or pastes from a
  # browser. Silently failing to match is worse than accepting them.
  test "normalizes case, trailing slashes, paths and default ports" do
    with_env("ALLOWED_ORIGINS" => "HTTPS://App.Example.com/, https://a.example.com:443, https://b.example.com/path") do
      assert_equal [ "https://app.example.com", "https://a.example.com", "https://b.example.com" ], CorsOrigins.list
    end
  end

  test "keeps a port that is not the default for the scheme" do
    with_env("ALLOWED_ORIGINS" => "http://app.example.com:3000") do
      assert_equal [ "http://app.example.com:3000" ], CorsOrigins.list
    end
  end

  test "drops entries that are not origins at all" do
    with_env("ALLOWED_ORIGINS" => "app.example.com, https://ok.example.com, not a url") do
      assert_equal [ "https://ok.example.com" ], CorsOrigins.list
    end
  end

  test "accepts an APP_DOMAIN that already carries a scheme" do
    with_env("ALLOWED_ORIGINS" => nil, "APP_DOMAIN" => "https://app.example.com/") do
      assert_equal [ "https://app.example.com" ], CorsOrigins.list
    end
  end
  private
    def with_env(values)
      previous = values.keys.index_with { |key| ENV[key] }
      values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
