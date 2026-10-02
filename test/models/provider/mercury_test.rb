require "test_helper"

class Provider::MercuryTest < ActiveSupport::TestCase
  def setup
    @provider = Provider::Mercury.new("test_token", base_url: "https://api-sandbox.mercury.com/api/v1")
  end

  test "initializes with token and default base_url" do
    provider = Provider::Mercury.new("my_token")
    assert_equal "my_token", provider.token
    assert_equal "https://api.mercury.com/api/v1", provider.base_url
  end

  test "initializes with custom base_url" do
    assert_equal "test_token", @provider.token
    assert_equal "https://api-sandbox.mercury.com/api/v1", @provider.base_url
  end

  # HTTParty resends caller-supplied headers on a redirect; its host-change
  # protection only covers basic_auth. The credential lives in a custom header
  # here, so a redirect off the allow-listed host would carry it along.
  test "does not follow a redirect off the allow-listed host with the credential" do
    stub_request(:get, "https://api-sandbox.mercury.com/api/v1/accounts")
      .to_return(status: 302, headers: { "Location" => "https://evil.example/collect" })
    leak = stub_request(:get, "https://evil.example/collect").to_return(status: 200, body: "{}")

    assert_raises(Provider::Mercury::MercuryError) { @provider.get_accounts }
    assert_not_requested leak
  end

  test "MercuryError includes error_type" do
    error = Provider::Mercury::MercuryError.new("Test error", :unauthorized)
    assert_equal "Test error", error.message
    assert_equal :unauthorized, error.error_type
  end

  test "MercuryError defaults error_type to unknown" do
    error = Provider::Mercury::MercuryError.new("Test error")
    assert_equal :unknown, error.error_type
  end
end
