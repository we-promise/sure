require "test_helper"

class Provider::AccountData::ApplicationCredentialsTest < ActiveSupport::TestCase
  test "EU connections resolve only the EU application grant" do
    Provider::PlaidAdapter.expects(:config_value).never
    Provider::PlaidEuAdapter.expects(:config_value).with(:environment).returns("production")
    Provider::PlaidEuAdapter.expects(:config_value).with(:client_id).returns("eu-client")
    Provider::PlaidEuAdapter.expects(:config_value).with(:secret).returns("eu-secret")
    connection = ProviderConnection.new(provider_key: "plaid", region: "eu", environment: "production")
    assert_equal({ client_id: "eu-client", secret: "eu-secret", region: "eu", environment: "production" },
      Provider::AccountData::ApplicationCredentials.build(connection))
  end

  test "an application environment change cannot silently rebind a connection token" do
    Provider::PlaidAdapter.expects(:config_value).with(:client_id).returns("us-client")
    Provider::PlaidAdapter.expects(:config_value).with(:secret).returns("us-secret")
    Provider::PlaidAdapter.expects(:config_value).with(:environment).returns("sandbox")
    connection = ProviderConnection.new(provider_key: "plaid", region: "us", environment: "production")
    error = assert_raises(Provider::AccountData::InvalidResponse) do
      Provider::AccountData::ApplicationCredentials.build(connection)
    end
    assert_equal "Plaid application and connection environments differ", error.message
  end

  test "missing regions and undeclared integrations cannot select application secrets" do
    Provider::PlaidAdapter.expects(:config_value).never
    assert_raises(Provider::AccountData::InvalidResponse) do
      Provider::AccountData::ApplicationCredentials.build(ProviderConnection.new(provider_key: "plaid"))
    end
    assert_raises(Provider::AccountData::UnsupportedCapability) do
      Provider::AccountData::ApplicationCredentials.build(ProviderConnection.new(provider_key: "up", region: "us"))
    end
  end

  test "legacy Indexa environment fallback is explicitly scoped" do
    with_env_overrides("INDEXA_API_TOKEN" => "legacy-indexa-token") do
      assert_equal({ api_token: "legacy-indexa-token" }, Provider::AccountData::ApplicationCredentials.fallback(ProviderConnection.new(provider_key: "indexa_capital")))
    end
    assert_raises(Provider::AccountData::UnsupportedCapability) do
      Provider::AccountData::ApplicationCredentials.fallback(ProviderConnection.new(provider_key: "up"))
    end
  end

  test "SnapTrade application credentials are supplied separately from connection tokens" do
    configured = OpenStruct.new(oauth_client_id: "app-client", oauth_client_secret: "app-secret")
    Rails.configuration.x.expects(:snaptrade).returns(configured)
    connection = ProviderConnection.new(provider_key: "snaptrade")
    assert_equal({ oauth_client_id: "app-client", oauth_client_secret: "app-secret" },
      Provider::AccountData::ApplicationCredentials.build(connection))
  end
end
