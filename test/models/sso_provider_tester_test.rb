require "test_helper"

class SsoProviderTesterTest < ActiveSupport::TestCase
  test "Russian connection results preserve protocol identifiers and issuer values" do
    expected = "https://issuer.example.test/realm/$&/"
    actual = expected.delete_suffix("/")
    provider = SsoProvider.new(strategy: "openid_connect", issuer: expected)
    response = stub(status: 200, success?: true, body: {
      issuer: actual,
      authorization_endpoint: "https://issuer.example.test/authorize",
      token_endpoint: "https://issuer.example.test/token"
    }.to_json)
    client = stub
    client.stubs(:get).returns(response)
    tester = SsoProviderTester.new(provider)
    tester.stubs(:faraday_client).returns(client)

    I18n.with_locale(:ru) do
      result = tester.test!
      assert_not result.success?
      assert_includes result.message, "Адрес издателя не совпадает"
      assert_includes result.message, "завершающим слешем"
      assert_includes result.message, expected
      assert_includes result.message, actual
      assert_equal({ expected: expected, actual: actual }, result.details)
    end
  end

  test "Russian OAuth validation localizes messages without claiming authentication" do
    I18n.with_locale(:ru) do
      { "google_oauth2" => "Google OAuth2", "github" => "GitHub OAuth" }.each do |strategy, label|
        provider = SsoProvider.new(strategy: strategy)
        assert_equal "Укажите идентификатор клиента", SsoProviderTester.new(provider).test!.message
        provider.client_id = "test-client"
        assert_equal "Укажите секрет клиента", SsoProviderTester.new(provider).test!.message
        provider.client_secret = "test-only"
        result = SsoProviderTester.new(provider).test!
        assert result.success?
        assert_equal "Настройки #{label} прошли предварительную проверку", result.message
        assert_equal "Full validation occurs during actual authentication", result.details[:note]
      end
    end
  end

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
