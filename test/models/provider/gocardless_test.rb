require "test_helper"

class Provider::GocardlessTest < ActiveSupport::TestCase
  setup do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @provider = Provider::Gocardless.new(secret_id: "test-id", secret_key: "test-key")
    @base = Provider::Gocardless::BASE_URL
    stub_request(:post, "#{@base}/api/v2/token/new/").to_return(status: 200, body: { access: "test-token", access_expires: 86400 }.to_json)
  end

  test "requests retain trailing slashes and cache the access token" do
    endpoint = stub_request(:get, "#{@base}/api/v2/institutions/?country=gb")
      .with(headers: { "Authorization" => "Bearer test-token" }).to_return(status: 200, body: [].to_json)
    2.times { assert_equal [], @provider.get_institutions(country: "GB") }
    assert_requested endpoint, times: 2
    assert_requested :post, "#{@base}/api/v2/token/new/", times: 1
  end

  test "retries an unauthorized response once then raises an authentication error" do
    stub_request(:get, "#{@base}/api/v2/institutions/?country=gb").to_return(status: 401, body: "{}")
    assert_raises Provider::Gocardless::AuthenticationError do
      @provider.get_institutions(country: "GB")
    end
    assert_requested :get, "#{@base}/api/v2/institutions/?country=gb", times: 2
    assert_requested :post, "#{@base}/api/v2/token/new/", times: 2
  end

  test "maps quota exhaustion without retrying account requests" do
    stub_request(:get, "#{@base}/api/v2/accounts/account-1/balances/").to_return(status: 429, body: "{}")
    error = assert_raises Provider::Gocardless::GocardlessError do
      @provider.get_account_balances(account_id: "account-1")
    end
    assert error.rate_limited?
    assert_requested :get, "#{@base}/api/v2/accounts/account-1/balances/", times: 1
  end

  test "rotating the secret key invalidates the cached token" do
    original = @provider.send(:token_cache_key)
    rotated = Provider::Gocardless.new(secret_id: "test-id", secret_key: "rotated-key")
    assert_not_equal original, rotated.send(:token_cache_key)
    assert_not_includes original, "test-key"
  end
end
