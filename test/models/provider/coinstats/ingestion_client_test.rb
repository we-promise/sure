require "test_helper"
require "ostruct"

class Provider::Coinstats::IngestionClientTest < ActiveSupport::TestCase
  setup do
    @client = Provider::Coinstats::IngestionClient.new(api_key: "private-key")
    @client.stubs(:sleep)
  end

  test "wallet request uses one exact scope and never follows redirects" do
    Provider::Coinstats.expects(:get).with("#{Provider::Coinstats::BASE_URL}/wallet/transactions", query: {
      wallets: "ethereum:0xABC", currency: "EUR", page: 2, limit: 100, from: "2020-01-01T00:00:00Z", to: "2026-09-15T00:00:00Z"
    }, headers: { "X-API-KEY" => "private-key", "Accept" => "application/json" }, follow_redirects: false)
      .returns(response('{"result":[{"amount":0.123456789012345678}],"meta":{"page":2,"limit":100}}'))
    result = @client.wallet_transactions(address: "0xABC", blockchain: "ethereum", currency: "EUR", page: 2,
      from: "2020-01-01T00:00:00Z", to: "2026-09-15T00:00:00Z")
    assert_equal BigDecimal("0.123456789012345678"), result.fetch("result").sole.fetch("amount")
    refute_includes @client.inspect, "private-key"
  end

  test "portfolio routing always supplies a portfolio ID instead of using all-portfolio aggregation" do
    Provider::Coinstats.expects(:get).with("#{Provider::Coinstats::BASE_URL}/portfolio/coins", has_entries(query: { portfolioId: "portfolio-1", page: 1, limit: 100 }))
      .returns(response('{"result":[]}'))
    assert_equal [], @client.portfolio_coins(portfolio_id: "portfolio-1").fetch("result")
    assert_raises(ArgumentError) { @client.portfolio_coins(portfolio_id: "") }
  end

  test "DeFi reader uses explicit address and chain without starting a portfolio sync" do
    Provider::Coinstats.expects(:get).with("#{Provider::Coinstats::BASE_URL}/wallet/defi", has_entries(query: { address: "0xABC", connectionId: "ethereum" }))
      .returns(response('{"protocols":[]}'))
    Provider::Coinstats.expects(:patch).never
    assert_equal [], @client.wallet_defi(address: "0xABC", blockchain: "ethereum").fetch("protocols")
  end

  test "wallet separators cannot inject another address or chain" do
    Provider::Coinstats.expects(:get).never
    [ [ "0xABC,bitcoin:other", "ethereum" ], [ "0xABC", "ethereum,bitcoin" ], [ "0xABC", "ethereum:other" ], [ "private\naddress", "ethereum" ] ].each do |address, chain|
      assert_raises(ArgumentError) { @client.wallet_balances(address: address, blockchain: chain) }
    end
  end

  test "page validation prevents an internal unbounded fetch loop" do
    Provider::Coinstats.expects(:get).never
    [ 0, -1, "2", 100_001, nil ].each do |page|
      assert_raises(ArgumentError) { @client.portfolio_coins(portfolio_id: "portfolio-1", page: page) }
    end
  end

  test "rate limits surface safe retry metadata after exactly one request" do
    Provider::Coinstats.expects(:get).once.returns(response("private upstream diagnostic", code: 429, headers: { "Retry-After" => "30" }))
    error = assert_raises(Provider::Coinstats::RateLimitError) { @client.wallet_balances(address: "0xABC", blockchain: "ethereum") }
    assert_equal 30, error.retry_after
    refute_includes error.message, "private"
  end

  test "unsynced history has an explicit recoverable readiness error without a hidden PATCH" do
    Provider::Coinstats.expects(:get).once.returns(response("private upstream diagnostic", code: 409))
    Provider::Coinstats.expects(:patch).never
    error = assert_raises(Provider::Coinstats::IngestionClient::NotReady) do
      @client.wallet_transactions(address: "0xABC", blockchain: "ethereum", currency: "USD", to: "2026-09-15T00:00:00Z")
    end
    refute_includes error.message, "private"
  end

  test "malformed bodies redirects and transport exceptions never expose financial data or keys" do
    [ response("private invalid JSON"), response("private redirect", code: 302), response("x" * (20.megabytes + 1)) ].each do |raw|
      Provider::Coinstats.expects(:get).once.returns(raw)
      error = assert_raises(Provider::Coinstats::Error) { @client.wallet_balances(address: "0xABC", blockchain: "ethereum") }
      refute_includes error.message, "private"
    end
    Provider::Coinstats.expects(:get).raises(Net::ReadTimeout, "private request key")
    error = assert_raises(Provider::Coinstats::Error) { @client.wallet_balances(address: "0xABC", blockchain: "ethereum") }
    refute_includes error.message, "private"
    assert_nil error.cause
  end

  private
    def response(body, code: 200, headers: {})
      OpenStruct.new(code: code, body: body, headers: headers)
    end
end
