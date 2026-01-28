require "test_helper"

class Provider::CoinstatsTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Coinstats.new("test_api_key")
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
