require "test_helper"

class DoorkeeperRedirectUriTest < ActiveSupport::TestCase
  test "rejects plain http redirect uris for non-loopback hosts" do
    app = Doorkeeper::Application.new(name: "Http client", redirect_uri: "http://example.com/callback")

    assert_not app.valid?
    assert app.errors[:redirect_uri].any?
  end

  test "allows https, loopback http and custom app schemes" do
    [
      "https://example.com/callback",
      "http://localhost:8787/callback",
      "http://LocalHost:8787/callback",
      "http://127.0.0.1/callback",
      "http://[::1]:3000/callback",
      MobileDevice::CALLBACK_URL
    ].each do |uri|
      app = Doorkeeper::Application.new(name: "Client", redirect_uri: uri)

      assert app.valid?, "#{uri} should be allowed: #{app.errors.full_messages.to_sentence}"
    end
  end
end
