require "test_helper"

class AllowedHostsTest < ActiveSupport::TestCase
  test "unions APP_DOMAIN with ALLOWED_HOSTS instead of choosing between them" do
    with_env_overrides(APP_DOMAIN: "app.example.com", ALLOWED_HOSTS: "10.0.0.5, box.tailnet.ts.net") do
      assert_equal [ "app.example.com", "10.0.0.5", "box.tailnet.ts.net" ], AllowedHosts.list
    end
  end

  test "drops blanks and duplicates" do
    with_env_overrides(APP_DOMAIN: "app.example.com", ALLOWED_HOSTS: " , app.example.com , ,10.0.0.5") do
      assert_equal [ "app.example.com", "10.0.0.5" ], AllowedHosts.list
    end
  end

  # An empty list must stay empty rather than becoming [""], which Rails would
  # read as an allow-list that matches nothing and reject every request.
  test "junk alone produces an empty list" do
    with_env_overrides(APP_DOMAIN: nil, ALLOWED_HOSTS: " , , ") do
      assert_empty AllowedHosts.list
    end
  end

  test "returns nothing when neither variable is set" do
    with_env_overrides(APP_DOMAIN: nil, ALLOWED_HOSTS: nil) do
      assert_empty AllowedHosts.list
    end
  end

  # config.hosts matches against the Host header, which is a bare hostname, so
  # a pasted URL has to be reduced to one or it silently matches nothing.
  test "reduces a pasted URL to a bare hostname" do
    with_env_overrides(APP_DOMAIN: "https://App.Example.com/path", ALLOWED_HOSTS: "http://10.0.0.5:3000") do
      assert_equal [ "app.example.com", "10.0.0.5" ], AllowedHosts.list
    end
  end

  # Rails reads a leading dot as "any subdomain of", so honouring it would turn
  # the allow-list into a wildcard for every name under the domain.
  test "refuses a leading dot instead of turning the list into a wildcard" do
    with_env_overrides(APP_DOMAIN: nil, ALLOWED_HOSTS: ".example.com,app.example.com") do
      assert_equal [ "app.example.com" ], AllowedHosts.list
      assert_equal [ ".example.com" ], AllowedHosts.rejected
    end
  end

  # The brackets are part of what Rails matches against the Host header, so
  # they stay and only the port comes off. Splitting on ":" turned these into
  # "[", which switched host authorization on with a list nothing could match.
  test "keeps IPv6 addresses usable" do
    with_env_overrides(APP_DOMAIN: nil, ALLOWED_HOSTS: "[::1]:3000,[2001:DB8::1]") do
      assert_equal [ "[::1]", "[2001:db8::1]" ], AllowedHosts.list
    end
  end

  # A browser sends "[::1]:3000", so an unbracketed entry would match nothing.
  test "brackets an IPv6 address written without them" do
    with_env_overrides(APP_DOMAIN: nil, ALLOWED_HOSTS: "::1") do
      assert_equal [ "[::1]" ], AllowedHosts.list
    end
  end

  test "reports nothing as rejected when every entry is usable" do
    with_env_overrides(APP_DOMAIN: "app.example.com", ALLOWED_HOSTS: "10.0.0.5") do
      assert_empty AllowedHosts.rejected
    end
  end

  # The tests above check the list; these run it through Rails' own
  # HostAuthorization middleware, configured the way production.rb configures
  # it, so they fail if the list stops meaning what Rails reads it as.
  test "lets the listed hosts through on any port and refuses any other Host" do
    with_env_overrides(APP_DOMAIN: "app.example.com", ALLOWED_HOSTS: "10.0.0.5,[::1]:3000") do
      assert_equal 200, status_for("app.example.com")
      assert_equal 200, status_for("app.example.com:8443")
      assert_equal 200, status_for("10.0.0.5:3000")
      assert_equal 200, status_for("[::1]:3000")
      assert_equal 403, status_for("rebound.attacker.test")
    end
  end

  test "a refused leading-dot entry does not let subdomains in" do
    with_env_overrides(APP_DOMAIN: nil, ALLOWED_HOSTS: ".example.com,app.example.com") do
      assert_equal 403, status_for("evil.example.com")
    end
  end

  # Probes reach /up over the pod IP or localhost, which no list contains.
  test "/up answers on any Host so container probes keep passing" do
    with_env_overrides(APP_DOMAIN: "app.example.com", ALLOWED_HOSTS: nil) do
      assert_equal 200, status_for("10.1.2.3:3000", path: "/up")
      assert_equal 403, status_for("10.1.2.3:3000", path: "/")
    end
  end

  private
    def status_for(host, path: "/")
      app = ->(_env) { [ 200, {}, [ "ok" ] ] }
      middleware = ActionDispatch::HostAuthorization.new(app, AllowedHosts.list, **AllowedHosts.host_authorization)
      middleware.call(Rack::MockRequest.env_for("http://placeholder#{path}", "HTTP_HOST" => host)).first
    end
end
