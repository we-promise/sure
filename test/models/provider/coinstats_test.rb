require "test_helper"

class Provider::CoinstatsTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Coinstats.new("test_api_key")
  end

  test "retries wallet requests on rate limit with retry after" do
    response = Struct.new(:code, :body, :headers)
    rate_limited_response = response.new(
      429,
      { message: "Too Many Requests" }.to_json,
      { "Retry-After" => "3" }
    )
    success_response = response.new(
      200,
      [ { blockchain: "ethereum", address: "0x123abc", balances: [] } ].to_json,
      {}
    )

    @provider.stubs(:min_request_interval).returns(0)
    @provider.expects(:sleep).with(3).once

    Provider::Coinstats.expects(:get)
      .with(
        "#{Provider::Coinstats::BASE_URL}/wallet/balances",
        headers: {
          "X-API-KEY" => "test_api_key",
          "Accept" => "application/json"
        },
        query: { wallets: "ethereum:0x123abc" }
      )
      .twice
      .returns(rate_limited_response, success_response)

    result = @provider.get_wallet_balances("ethereum:0x123abc")

    assert result.success?
    assert_equal "ethereum", result.data.first[:blockchain]
  end

  test "maps CoinStats credit limit responses without retrying" do
    response = Struct.new(:code, :body, :headers)
    credit_limited_response = response.new(
      406,
      {
        statusCode: 406,
        message: "Credits limit reached. Please upgrade your plan or wait for renewal.",
        requestId: "test-request-id",
        path: "/wallet/defi"
      }.to_json,
      {}
    )

    @provider.stubs(:min_request_interval).returns(0)
    @provider.expects(:sleep).never

    Provider::Coinstats.expects(:get)
      .with(
        "#{Provider::Coinstats::BASE_URL}/wallet/defi",
        headers: {
          "X-API-KEY" => "test_api_key",
          "Accept" => "application/json"
        },
        query: { address: "0x123abc", connectionId: "ethereum" }
      )
      .once
      .returns(credit_limited_response)

    result = @provider.get_wallet_defi(address: "0x123abc", connection_id: "ethereum")

    refute result.success?
    assert_match "Credits limit reached", result.error.message
    assert_equal 406, result.error.details[:status_code]
  end

  test "extract_wallet_balance finds matching wallet by address and connectionId" do
    bulk_data = [
      {
        blockchain: "ethereum",
        address: "0x123abc",
        connectionId: "ethereum",
        balances: [
          { coinId: "ethereum", name: "Ethereum", amount: 1.5, price: 2000 }
        ]
      },
      {
        blockchain: "bitcoin",
        address: "bc1qxyz",
        connectionId: "bitcoin",
        balances: [
          { coinId: "bitcoin", name: "Bitcoin", amount: 0.5, price: 50000 }
        ]
      }
    ]

    result = @provider.extract_wallet_balance(bulk_data, "0x123abc", "ethereum")

    assert_equal 1, result.size
    assert_equal "ethereum", result.first[:coinId]
  end

  test "extract_wallet_balance handles case insensitive matching" do
    bulk_data = [
      {
        blockchain: "Ethereum",
        address: "0x123ABC",
        connectionId: "Ethereum",
        balances: [
          { coinId: "ethereum", name: "Ethereum", amount: 1.5, price: 2000 }
        ]
      }
    ]

    result = @provider.extract_wallet_balance(bulk_data, "0x123abc", "ethereum")

    assert_equal 1, result.size
    assert_equal "ethereum", result.first[:coinId]
  end

  test "extract_wallet_balance returns empty array when wallet not found" do
    bulk_data = [
      {
        blockchain: "ethereum",
        address: "0x123abc",
        connectionId: "ethereum",
        balances: [
          { coinId: "ethereum", name: "Ethereum", amount: 1.5, price: 2000 }
        ]
      }
    ]

    result = @provider.extract_wallet_balance(bulk_data, "0xnotfound", "ethereum")

    assert_equal [], result
  end

  test "extract_wallet_balance returns empty array for nil bulk_data" do
    result = @provider.extract_wallet_balance(nil, "0x123abc", "ethereum")

    assert_equal [], result
  end

  test "extract_wallet_balance returns empty array for non-array bulk_data" do
    result = @provider.extract_wallet_balance({ error: "invalid" }, "0x123abc", "ethereum")

    assert_equal [], result
  end

  test "extract_wallet_balance matches by blockchain when connectionId differs" do
    bulk_data = [
      {
        blockchain: "ethereum",
        address: "0x123abc",
        connectionId: "eth-mainnet", # Different connectionId
        balances: [
          { coinId: "ethereum", name: "Ethereum", amount: 1.5, price: 2000 }
        ]
      }
    ]

    result = @provider.extract_wallet_balance(bulk_data, "0x123abc", "ethereum")

    assert_equal 1, result.size
  end

  test "extract_wallet_transactions finds matching wallet transactions" do
    bulk_data = [
      {
        blockchain: "ethereum",
        address: "0x123abc",
        connectionId: "ethereum",
        transactions: [
          { hash: { id: "0xtx1" }, type: "Received", date: "2025-01-01T10:00:00.000Z" },
          { hash: { id: "0xtx2" }, type: "Sent", date: "2025-01-02T11:00:00.000Z" }
        ]
      },
      {
        blockchain: "bitcoin",
        address: "bc1qxyz",
        connectionId: "bitcoin",
        transactions: [
          { hash: { id: "btctx1" }, type: "Received", date: "2025-01-03T12:00:00.000Z" }
        ]
      }
    ]

    result = @provider.extract_wallet_transactions(bulk_data, "0x123abc", "ethereum")

    assert_equal 2, result.size
    assert_equal "0xtx1", result.first[:hash][:id]
  end

  test "extract_wallet_transactions returns empty array when wallet not found" do
    bulk_data = [
      {
        blockchain: "ethereum",
        address: "0x123abc",
        connectionId: "ethereum",
        transactions: [
          { hash: { id: "0xtx1" }, type: "Received" }
        ]
      }
    ]

    result = @provider.extract_wallet_transactions(bulk_data, "0xnotfound", "ethereum")

    assert_equal [], result
  end

  test "extract_wallet_transactions returns empty array for nil bulk_data" do
    result = @provider.extract_wallet_transactions(nil, "0x123abc", "ethereum")

    assert_equal [], result
  end

  test "extract_wallet_transactions handles case insensitive matching" do
    bulk_data = [
      {
        blockchain: "Ethereum",
        address: "0x123ABC",
        connectionId: "Ethereum",
        transactions: [
          { hash: { id: "0xtx1" }, type: "Received" }
        ]
      }
    ]

    result = @provider.extract_wallet_transactions(bulk_data, "0x123abc", "ethereum")

    assert_equal 1, result.size
  end
end
