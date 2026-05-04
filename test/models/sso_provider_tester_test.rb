require "test_helper"

class SsoProviderTesterTest < ActiveSupport::TestCase
  test "oidc discovery requires exact issuer match" do
    provider = SsoProvider.new(
      strategy: "openid_connect",
      name: "pocket_id",
      label: "Pocket ID",
      issuer: "https://pocketid.example.com/",
      client_id: "client-id",
      client_secret: "secret"
    )

    response = stub(status: 200, success?: true, body: {
      issuer: "https://pocketid.example.com",
      authorization_endpoint: "https://pocketid.example.com/authorize",
      token_endpoint: "https://pocketid.example.com/api/oidc/token"
    }.to_json)

    client = stub
    client.stubs(:get).returns(response)

    tester = SsoProviderTester.new(provider)
    tester.stubs(:faraday_client).returns(client)

    result = tester.test!

    assert_not result.success?
    assert_includes result.message, "Issuer mismatch"
    assert_includes result.message, "trailing slash mismatch"
    assert_equal "https://pocketid.example.com/", result.details[:expected]
    assert_equal "https://pocketid.example.com", result.details[:actual]
  end
end
