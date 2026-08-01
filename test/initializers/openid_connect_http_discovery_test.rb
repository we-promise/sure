# frozen_string_literal: true

require "test_helper"

# Regression coverage for https://github.com/we-promise/sure/issues/2844 - a
# self-hosted IdP served over plain HTTP was upgraded to https:443 during discovery.
class OpenIDConnectHttpDiscoveryTest < ActiveSupport::TestCase
  Resource = OpenIDConnect::Discovery::Provider::Config::Resource

  test "http issuer builds an http discovery endpoint" do
    endpoint = Resource.new(URI.parse("http://auth.example")).endpoint

    assert_equal "http://auth.example/.well-known/openid-configuration", endpoint.to_s
  end

  test "https issuer still builds an https discovery endpoint" do
    endpoint = Resource.new(URI.parse("https://auth.example")).endpoint

    assert_equal "https://auth.example/.well-known/openid-configuration", endpoint.to_s
  end

  test "custom http port is preserved" do
    endpoint = Resource.new(URI.parse("http://auth.example:9000")).endpoint

    assert_equal "http://auth.example:9000/.well-known/openid-configuration", endpoint.to_s
  end

  test "explicit non-default port is preserved per scheme" do
    http_443 = Resource.new(URI.parse("http://auth.example:443")).endpoint
    https_80 = Resource.new(URI.parse("https://auth.example:80")).endpoint

    assert_equal "http://auth.example:443/.well-known/openid-configuration", http_443.to_s
    assert_equal "https://auth.example:80/.well-known/openid-configuration", https_80.to_s
  end

  test "cache key varies by scheme, port, and path on the same host" do
    baseline = cache_key_for("http://auth.example")
    other_scheme = cache_key_for("https://auth.example")
    other_port = cache_key_for("http://auth.example:9000")
    other_path = cache_key_for("http://auth.example/application/o/sure")

    keys = [ baseline, other_scheme, other_port, other_path ]
    assert_equal keys.length, keys.uniq.length, "each of scheme/port/path must produce a distinct cache key"
  end

  test "issuer path prefix is preserved" do
    endpoint = Resource.new(URI.parse("http://auth.example/application/o/sure")).endpoint

    assert_equal "http://auth.example/application/o/sure/.well-known/openid-configuration", endpoint.to_s
  end

  private
    def cache_key_for(issuer)
      Resource.new(URI.parse(issuer)).send(:cache_key)
    end
end
