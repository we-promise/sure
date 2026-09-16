require "test_helper"

class Provider::IndexaCapitalIngestionTest < ActiveSupport::TestCase
  setup do
    @client = Provider::IndexaCapital.new(api_token: "private-token")
  end

  test "native fiscal reads retain exact decimals and token authentication" do
    stub_request(:get, "https://api.indexacapital.com/accounts/ACCOUNT1/fiscal-results")
      .with(headers: { "X-AUTH-TOKEN" => "private-token" })
      .to_return(status: 200, body: '{"total_fiscal_results":[{"price":1.234567890123456789,"titles":2.5}]}')
    data = @client.get_ingestion_fiscal_results(account_number: "ACCOUNT1")
    assert_equal BigDecimal("1.234567890123456789"), data[:total_fiscal_results].first[:price]
  end

  test "native username authentication is captured only inside the transport" do
    client = Provider::IndexaCapital.new(username: "user", document: "identity", password: "password")
    stub_request(:post, "https://api.indexacapital.com/auth/authenticate")
      .with(body: { username: "user", document: "identity", password: "password" }.to_json)
      .to_return(status: 200, body: '{"token":"session-token"}')
    stub_request(:get, "https://api.indexacapital.com/users/me").with(headers: { "X-AUTH-TOKEN" => "session-token" })
      .to_return(status: 200, body: '{"accounts":[]}')
    assert_equal({ accounts: [] }, client.get_ingestion_accounts)
  end

  test "unsafe account IDs cannot enter a request path or an error message" do
    error = assert_raises(Provider::IndexaCapital::Error) { @client.get_ingestion_performance(account_number: "private/../account") }
    refute_includes error.message, "private/../account"
  end

  test "upstream errors and malformed JSON do not disclose response bodies" do
    [ 400, 401, 403, 500 ].each do |status|
      stub_request(:get, "https://api.indexacapital.com/users/me").to_return(status: status, body: "private-financial-data")
      error = assert_raises(Provider::IndexaCapital::Error) { @client.get_ingestion_accounts }
      refute_includes error.message, "private-financial-data"
      assert_nil error.cause
    end
    stub_request(:get, "https://api.indexacapital.com/users/me").to_return(status: 200, body: "private-malformed-json")
    error = assert_raises(Provider::IndexaCapital::Error) { @client.get_ingestion_accounts }
    refute_includes error.message, "private-malformed-json"
  end

  test "network retries are bounded and retain the original read operation" do
    @client.stubs(:sleep)
    stub_request(:get, "https://api.indexacapital.com/users/me").to_raise(Net::ReadTimeout)
    error = assert_raises(Provider::IndexaCapital::Error) { @client.get_ingestion_accounts }
    assert_equal :network_error, error.error_type
    assert_requested :get, "https://api.indexacapital.com/users/me", times: 4
  end
end
