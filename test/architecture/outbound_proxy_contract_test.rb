require "test_helper"

# Every Net::HTTP connection Sure opens itself takes its proxy from ProxyConfigurable, so
# HTTPS_PROXY, NO_PROXY and loopback are read the same way everywhere. Left to itself,
# Net::HTTP reads only HTTP_PROXY, even for an HTTPS target.
class OutboundProxyContractTest < ActiveSupport::TestCase
  # Every Net::HTTP entry point that opens a connection, including the proxy class factory.
  CONNECTION = /\bNet::HTTP(?:\.(?:new|start|get|get_response|get_print|post|post_form)\b|(?:::|\.)Proxy\b)/
  RESOLVED = /\bnet_http_proxy_args\b/

  # Each entry says why the file may connect without the resolver.
  ALLOWED = {
    "lib/llm_pricing_updater.rb" => "run by bin/update_llm_pricing on a developer machine, never by the app"
  }.freeze

  test "every Net::HTTP connection under app/ and lib/ resolves its proxy" do
    files = Dir[Rails.root.join("{app,lib}/**/*.{rb,rake}")].map { Pathname(_1).relative_path_from(Rails.root).to_s }

    assert_empty files.select { unresolved?(_1, File.read(Rails.root.join(_1))) },
      "These files open a Net::HTTP connection without ProxyConfigurable#net_http_proxy_args"
  end

  test "every HTTParty client resolves its proxy" do
    files = Dir[Rails.root.join("{app,lib}/**/*.{rb,rake,tt}")].map { Pathname(_1).relative_path_from(Rails.root).to_s }
    assert_empty files.select { bare_httparty?(_1, File.read(Rails.root.join(_1))) },
      "These files use HTTParty without ProxiedHttparty, or call HTTParty.get and friends directly"

    # Only named classes defined under app/, so classes a test or a gem defines (HTTParty's own
    # Basement, a stubbed instance's singleton class) can't change the result.
    Rails.application.eager_load!
    app = "#{Rails.root.join("app")}/"
    clients = ObjectSpace.each_object(Class).select do |klass|
      next false unless klass.singleton_class.include?(HTTParty::ClassMethods)

      name = Module.instance_method(:name).bind_call(klass)
      name && Object.const_source_location(name)&.first&.start_with?(app)
    end
    assert_includes clients, Provider::Kraken
    assert_empty clients.reject { proxied_adapter?(_1.default_options[:connection_adapter]) }.map(&:to_s),
      "These HTTParty clients do not connect through ProxiedHttparty::ConnectionAdapter"
  end

  test "the HTTParty scan flags an include, an adapter and a direct call, and skips a comment" do
    assert bare_httparty?("app/models/provider/example.rb", "  include HTTParty\n")
    assert bare_httparty?("app/models/provider/example.rb", "  class PinnedAdapter < HTTParty::ConnectionAdapter\n")
    assert_not bare_httparty?("app/models/provider/example.rb", "  #     include HTTParty\n")
    assert_not bare_httparty?("app/models/provider/example.rb", "  include ProxiedHttparty\n")
    assert bare_httparty?("app/models/provider/example.rb", "    HTTParty.get(url)\n")
    assert bare_httparty?("app/models/provider/example.rb", "  include ::HTTParty\n")
    assert bare_httparty?("app/models/provider/example.rb", "    HTTParty::Request.new(Net::HTTP::Get, url).perform\n")
    assert_not bare_httparty?("app/models/concerns/proxied_httparty.rb", "  include HTTParty\n")
  end

  test "an adapter that is missing, a Proc, or another class is reported, not raised on" do
    assert proxied_adapter?(ProxiedHttparty::ConnectionAdapter)
    assert proxied_adapter?(Provider::Simplefin::PinnedConnectionAdapter)
    assert_not proxied_adapter?(nil)
    assert_not proxied_adapter?(->(uri, options) { Net::HTTP.new(uri.host, uri.port) })
    assert_not proxied_adapter?(HTTParty::ConnectionAdapter)
  end

  test "the scan flags a connection, skips a comment, and allows only the listed files" do
    assert unresolved?("app/models/example.rb", "    Net::HTTP.start(host, port, use_ssl: true) do |http|\n")
    assert unresolved?("app/models/example.rb", "Net::HTTP.get_response(URI(url))\n")
    assert unresolved?("app/models/example.rb", "Net::HTTP.post_form(uri, params)\n")
    assert unresolved?("app/models/example.rb", "Net::HTTP.post(uri, body)\n")
    assert unresolved?("app/models/example.rb", "Net::HTTP::Proxy(host, port).start(uri.host)\n")
    assert_not unresolved?("app/models/example.rb", "request = Net::HTTP::Post.new(uri)\n")
    assert_not unresolved?("app/models/example.rb", "  # http = Net::HTTP.new(uri.host, uri.port)\n")
    assert_not unresolved?("app/models/example.rb", "Net::HTTP.new(host, port, *self.class.net_http_proxy_args(url))\n")

    pricing = File.read(Rails.root.join("lib/llm_pricing_updater.rb"))
    assert_not unresolved?("lib/llm_pricing_updater.rb", pricing)
    assert unresolved?("lib/other_updater.rb", pricing)
  end

  private
    def bare_httparty?(path, source)
      return false if path == "app/models/concerns/proxied_httparty.rb"

      code(source).match?(/\binclude\s+(?:::)?HTTParty\b|<\s*(?:::)?HTTParty::ConnectionAdapter\b|\bHTTParty(?:\.(?:get|post|put|patch|delete|head|options)\b|::Request\b)/)
    end

    def proxied_adapter?(adapter) = adapter.is_a?(Class) && adapter <= ProxiedHttparty::ConnectionAdapter

    def code(source) = source.lines.reject { _1.lstrip.start_with?("#") }.join

    def unresolved?(path, source)
      return false if ALLOWED.key?(path)

      code = code(source)
      code.match?(CONNECTION) && !code.match?(RESOLVED)
    end
end
