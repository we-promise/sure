require "test_helper"

class SslConfigurableTest < ActiveSupport::TestCase
  # Create a simple test host that extends SslConfigurable, mirroring how
  # providers use it in the actual codebase.
  class SslTestHost
    extend SslConfigurable
  end

  setup do
    # Snapshot original config so we can restore it in teardown
    @original_verify = Rails.configuration.x.ssl.verify
    @original_ca_file = Rails.configuration.x.ssl.ca_file
    @original_debug = Rails.configuration.x.ssl.debug
  end

  teardown do
    Rails.configuration.x.ssl.verify = @original_verify
    Rails.configuration.x.ssl.ca_file = @original_ca_file
    Rails.configuration.x.ssl.debug = @original_debug
  end

  # -- ssl_verify? --

  test "ssl_verify? returns true when verify is nil (default)" do
    Rails.configuration.x.ssl.verify = nil
    assert SslTestHost.ssl_verify?
  end

  test "ssl_verify? returns true when verify is true" do
    Rails.configuration.x.ssl.verify = true
    assert SslTestHost.ssl_verify?
  end

  test "ssl_verify? returns false when verify is explicitly false" do
    Rails.configuration.x.ssl.verify = false
    refute SslTestHost.ssl_verify?
  end

  # -- ssl_ca_file --

  test "ssl_ca_file returns nil when no CA file is configured" do
    Rails.configuration.x.ssl.ca_file = nil
    assert_nil SslTestHost.ssl_ca_file
  end

  test "ssl_ca_file returns the configured path" do
    Rails.configuration.x.ssl.ca_file = "/certs/my-ca.crt"
    assert_equal "/certs/my-ca.crt", SslTestHost.ssl_ca_file
  end

  # -- ssl_debug? --

  test "ssl_debug? returns false when debug is nil" do
    Rails.configuration.x.ssl.debug = nil
    refute SslTestHost.ssl_debug?
  end

  test "ssl_debug? returns true when debug is true" do
    Rails.configuration.x.ssl.debug = true
    assert SslTestHost.ssl_debug?
  end

  # -- faraday_ssl_options --

  test "faraday_ssl_options returns verify true with no CA file by default" do
    Rails.configuration.x.ssl.verify = true
    Rails.configuration.x.ssl.ca_file = nil
    Rails.configuration.x.ssl.debug = false

    options = SslTestHost.faraday_ssl_options

    assert_equal true, options[:verify]
    assert_nil options[:ca_file]
  end

  test "faraday_ssl_options includes ca_file when configured" do
    Rails.configuration.x.ssl.verify = true
    Rails.configuration.x.ssl.ca_file = "/certs/my-ca.crt"
    Rails.configuration.x.ssl.debug = false

    options = SslTestHost.faraday_ssl_options

    assert_equal true, options[:verify]
    assert_equal "/certs/my-ca.crt", options[:ca_file]
  end

  test "faraday_ssl_options returns verify false when verification disabled" do
    Rails.configuration.x.ssl.verify = false
    Rails.configuration.x.ssl.ca_file = nil
    Rails.configuration.x.ssl.debug = false

    options = SslTestHost.faraday_ssl_options

    assert_equal false, options[:verify]
  end

  test "faraday_ssl_options includes both verify false and ca_file when both configured" do
    Rails.configuration.x.ssl.verify = false
    Rails.configuration.x.ssl.ca_file = "/certs/my-ca.crt"
    Rails.configuration.x.ssl.debug = false

    options = SslTestHost.faraday_ssl_options

    assert_equal false, options[:verify]
    assert_equal "/certs/my-ca.crt", options[:ca_file]
  end

  # -- httparty_ssl_options --

  test "httparty_ssl_options returns verify true with no CA file by default" do
    Rails.configuration.x.ssl.verify = true
    Rails.configuration.x.ssl.ca_file = nil
    Rails.configuration.x.ssl.debug = false

    options = SslTestHost.httparty_ssl_options

    assert_equal true, options[:verify]
    assert_nil options[:ssl_ca_file]
  end

  test "httparty_ssl_options includes ssl_ca_file when configured" do
    Rails.configuration.x.ssl.verify = true
    Rails.configuration.x.ssl.ca_file = "/certs/my-ca.crt"
    Rails.configuration.x.ssl.debug = false

    options = SslTestHost.httparty_ssl_options

    assert_equal true, options[:verify]
    assert_equal "/certs/my-ca.crt", options[:ssl_ca_file]
  end

  test "httparty_ssl_options returns verify false when verification disabled" do
    Rails.configuration.x.ssl.verify = false
    Rails.configuration.x.ssl.ca_file = nil
    Rails.configuration.x.ssl.debug = false

    options = SslTestHost.httparty_ssl_options

    assert_equal false, options[:verify]
  end

  # -- net_http_verify_mode --

  test "net_http_verify_mode returns VERIFY_PEER when verification enabled" do
    Rails.configuration.x.ssl.verify = true
    Rails.configuration.x.ssl.debug = false

    assert_equal OpenSSL::SSL::VERIFY_PEER, SslTestHost.net_http_verify_mode
  end

  test "net_http_verify_mode returns VERIFY_NONE when verification disabled" do
    Rails.configuration.x.ssl.verify = false
    Rails.configuration.x.ssl.debug = false

    assert_equal OpenSSL::SSL::VERIFY_NONE, SslTestHost.net_http_verify_mode
  end

  test "net_http_verify_mode returns VERIFY_PEER when verify is nil" do
    Rails.configuration.x.ssl.verify = nil
    Rails.configuration.x.ssl.debug = false

    assert_equal OpenSSL::SSL::VERIFY_PEER, SslTestHost.net_http_verify_mode
  end
end
