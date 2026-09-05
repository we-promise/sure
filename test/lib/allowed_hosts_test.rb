require "test_helper"

class AllowedHostsTest < ActiveSupport::TestCase
  test "unions APP_DOMAIN with ALLOWED_HOSTS instead of choosing between them" do
    with_env("APP_DOMAIN" => "app.example.com", "ALLOWED_HOSTS" => "10.0.0.5, box.tailnet.ts.net") do
      assert_equal [ "app.example.com", "10.0.0.5", "box.tailnet.ts.net" ], AllowedHosts.list
    end
  end

  test "drops blanks and duplicates" do
    with_env("APP_DOMAIN" => "app.example.com", "ALLOWED_HOSTS" => " , app.example.com , ,10.0.0.5") do
      assert_equal [ "app.example.com", "10.0.0.5" ], AllowedHosts.list
    end
  end

  # An empty list must stay empty rather than becoming [""], which Rails would
  # read as an allow-list that matches nothing and reject every request.
  test "junk alone produces an empty list" do
    with_env("APP_DOMAIN" => nil, "ALLOWED_HOSTS" => " , , ") do
      assert_empty AllowedHosts.list
    end
  end

  test "returns nothing when neither variable is set" do
    with_env("APP_DOMAIN" => nil, "ALLOWED_HOSTS" => nil) do
      assert_empty AllowedHosts.list
    end
  end


  # config.hosts matches against the Host header, which is a bare hostname, so
  # a pasted URL has to be reduced to one or it silently matches nothing.
  test "reduces a pasted URL to a bare hostname" do
    with_env("APP_DOMAIN" => "https://App.Example.com/path", "ALLOWED_HOSTS" => "http://10.0.0.5:3000") do
      assert_equal [ "app.example.com", "10.0.0.5" ], AllowedHosts.list
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
