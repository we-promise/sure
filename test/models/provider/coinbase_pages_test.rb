require "test_helper"

class Provider::CoinbasePagesTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body, keyword_init: true)

  setup do
    @client = Provider::Coinbase.new(api_key: "key", api_secret: "secret")
    @client.stubs(:auth_headers).returns({ "Authorization" => "Bearer test-token" })
  end

  test "bounded readers parse exact decimal JSON and retain original evidence" do
    Provider::Coinbase.expects(:get).once.with("/v2/accounts?limit=100", headers: { "Authorization" => "Bearer test-token" })
      .returns(response('{"data":[{"id":"wallet","balance":{"amount":0.123456789012345678}}],"pagination":{"next_uri":null}}'))

    result = @client.get_accounts_page

    assert_equal BigDecimal("0.123456789012345678"), result[:items].first.dig("balance", "amount")
    assert_equal result[:items], result[:evidence]["data"]
    assert_nil result[:next_cursor]
  end

  test "continuation preserves all query parameters and signs only the resource path" do
    path = "/v2/accounts/wallet/transactions?limit=100&starting_after=next&order=asc"
    @client.expects(:auth_headers).with("GET", "/v2/accounts/wallet/transactions").returns({ "Authorization" => "Bearer signed-path" })
    Provider::Coinbase.expects(:get).once.with(path, headers: { "Authorization" => "Bearer signed-path" })
      .returns(response({ data: [ { id: "one" } ], pagination: { next_uri: path.sub("=next", "=last") } }.to_json))

    result = @client.get_transactions_page("wallet", cursor: path)

    assert_includes result[:next_cursor], "starting_after=last&order=asc"
    assert_equal 1, result[:items].size
  end

  test "foreign host fragment other wallet and other resource continuations never receive credentials" do
    Provider::Coinbase.expects(:get).never
    [ "https://attacker.test/v2/accounts/wallet/transactions", "//attacker.test/v2/accounts/wallet/transactions",
      "/v2/accounts/wallet/transactions#secret", "/v2/accounts/other/transactions?starting_after=x",
      "/v2/accounts/wallet/buys?starting_after=x" ].each do |cursor|
      assert_raises(Provider::Coinbase::ApiError) { @client.get_transactions_page("wallet", cursor: cursor) }
    end
    [ "../wallet", "wallet?include=secret", "wallet/other" ].each do |identifier|
      assert_raises(Provider::Coinbase::ApiError) { @client.get_account_page(identifier) }
    end
  end

  test "missing pagination malformed rows and oversized pages cannot claim completion" do
    [ {}, { data: [] }, { data: nil, pagination: { next_uri: nil } },
      { data: [ nil ], pagination: { next_uri: nil } }, { data: [], pagination: { next_uri: false } },
      { data: Array.new(101) { { id: "wallet" } }, pagination: { next_uri: nil } } ].each do |payload|
      Provider::Coinbase.expects(:get).once.returns(response(payload.to_json))
      assert_raises(Provider::Coinbase::ApiError) { @client.get_accounts_page }
    end
  end

  test "public spot valuation sends no credentials and preserves fractional precision" do
    @client.expects(:auth_headers).never
    Provider::Coinbase.expects(:get).with("/v2/prices/BTC-EUR/spot", timeout: 10)
      .returns(response('{"data":{"amount":66580.123456789012345678,"currency":"EUR"}}'))

    result = @client.get_spot_price_page("BTC-EUR")

    assert_equal BigDecimal("66580.123456789012345678"), result[:items].first["amount"]
  end

  test "authorization rate limit and API errors are typed and omit private response messages" do
    { 401 => Provider::Coinbase::AuthenticationError, 403 => Provider::Coinbase::AuthenticationError,
      429 => Provider::Coinbase::RateLimitError, 500 => Provider::Coinbase::ApiError }.each do |status, error_class|
      Provider::Coinbase.expects(:get).returns(response('{"errors":[{"message":"private financial details"}]}', code: status))
      error = assert_raises(error_class) { @client.get_transactions_page("wallet") }
      refute_includes error.message, "private financial details"
    end
    Provider::Coinbase.expects(:get).returns(response("invalid private financial JSON"))
    error = assert_raises(Provider::Coinbase::ApiError) { @client.get_account_page("wallet") }
    assert_nil error.cause
    refute_includes error.message, "private financial"
  end

  test "legacy buy and sell readers remain separately bounded for explicit migration replay" do
    %w[buys sells].each do |resource|
      Provider::Coinbase.expects(:get).once.with("/v2/accounts/wallet/#{resource}?limit=100", headers: { "Authorization" => "Bearer test-token" })
        .returns(response({ data: [], pagination: { next_uri: nil } }.to_json))
      assert_empty @client.public_send("get_#{resource}_page", "wallet")[:items]
    end
  end

  private
    def response(body, code: 200)
      Response.new(code: code, body: body)
    end
end
