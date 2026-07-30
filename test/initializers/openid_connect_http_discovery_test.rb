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

  test "issuer path prefix is preserved" do
    endpoint = Resource.new(URI.parse("http://auth.example/application/o/sure")).endpoint

    assert_equal "http://auth.example/application/o/sure/.well-known/openid-configuration", endpoint.to_s
  end
end
