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
    def unresolved?(path, source)
      return false if ALLOWED.key?(path)

      code = source.lines.reject { _1.lstrip.start_with?("#") }.join
      code.match?(CONNECTION) && !code.match?(RESOLVED)
    end
end
