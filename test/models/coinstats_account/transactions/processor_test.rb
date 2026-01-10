require "test_helper"

class CoinstatsAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @coinstats_item = CoinstatsItem.create!(
      family: @family,
      name: "Test CoinStats Connection",
      api_key: "test_api_key_123"
    )
    @crypto = Crypto.create!
    @account = @family.accounts.create!(
      accountable: @crypto,
      name: "Test ETH Account",
      balance: 5000,
      currency: "USD"
    )
    @coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Ethereum Wallet",
      currency: "USD",
      current_balance: 5000,
      account_id: "ethereum"
    )
    AccountProvider.create!(account: @account, provider: @coinstats_account)
  end

  test "returns early when no transactions payload" do
    @coinstats_account.update!(raw_transactions_payload: nil)

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)
    result = processor.process

    assert result[:success]
    assert_equal 0, result[:total]
    assert_equal 0, result[:imported]
    assert_equal 0, result[:failed]
    assert_empty result[:errors]
  end

  test "processes transactions from raw_transactions_payload" do
    @coinstats_account.update!(raw_transactions_payload: [
      {
        type: "Received",
        date: "2025-01-15T10:00:00.000Z",
        coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
        hash: { id: "0xprocess1" },
        transactions: [ { items: [ { coin: { id: "ethereum" } } ] } ]
      }
    ])

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    assert_difference "Entry.count", 1 do
      result = processor.process
      assert result[:success]
      assert_equal 1, result[:total]
      assert_equal 1, result[:imported]
      assert_equal 0, result[:failed]
    end
  end

  test "filters transactions to only process matching coin" do
    @coinstats_account.update!(raw_transactions_payload: [
      {
        type: "Received",
        date: "2025-01-15T10:00:00.000Z",
        coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
        hash: { id: "0xmatch1" },
        transactions: [ { items: [ { coin: { id: "ethereum" } } ] } ]
      },
      {
        type: "Received",
        date: "2025-01-16T10:00:00.000Z",
        coinData: { count: 100, symbol: "USDC", currentValue: 100 },
        hash: { id: "0xdifferent" },
        transactions: [ { items: [ { coin: { id: "usd-coin" } } ] } ]
      }
    ])

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    # Should only process the ETH transaction
    assert_difference "Entry.count", 1 do
      result = processor.process
      assert result[:success]
      assert_equal 1, result[:total]
    end

    # Verify the correct transaction was imported
    entry = @account.entries.last
    assert_equal "coinstats_0xmatch1", entry.external_id
  end

  test "handles transaction processing errors gracefully" do
    @coinstats_account.update!(raw_transactions_payload: [
      {
        # Invalid transaction - missing required fields
        type: "Received",
        coinData: { count: 1.0, symbol: "ETH" },
        transactions: [ { items: [ { coin: { id: "ethereum" } } ] } ]
        # Missing date and hash
      }
    ])

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    assert_no_difference "Entry.count" do
      result = processor.process
      refute result[:success]
      assert_equal 1, result[:total]
      assert_equal 0, result[:imported]
      assert_equal 1, result[:failed]
      assert_equal 1, result[:errors].count
    end
  end

  test "processes multiple valid transactions" do
    @coinstats_account.update!(raw_transactions_payload: [
      {
        type: "Received",
        date: "2025-01-15T10:00:00.000Z",
        coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
        hash: { id: "0xmulti1" },
        transactions: [ { items: [ { coin: { id: "ethereum" } } ] } ]
      },
      {
        type: "Sent",
        date: "2025-01-16T10:00:00.000Z",
        coinData: { count: -0.5, symbol: "ETH", currentValue: 1000 },
        hash: { id: "0xmulti2" },
        transactions: [ { items: [ { coin: { id: "ethereum" } } ] } ]
      }
    ])

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    assert_difference "Entry.count", 2 do
      result = processor.process
      assert result[:success]
      assert_equal 2, result[:total]
      assert_equal 2, result[:imported]
    end
  end

  test "matches by coin symbol in coinData as fallback" do
    @coinstats_account.update!(
      name: "ETH Wallet",
      account_id: "ethereum",
      raw_transactions_payload: [
        {
          type: "Received",
          date: "2025-01-15T10:00:00.000Z",
          coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
          hash: { id: "0xsymbol1" }
          # No transactions array with coin.id
        }
      ]
    )

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    assert_difference "Entry.count", 1 do
      result = processor.process
      assert result[:success]
    end
  end

  test "processes all transactions when no account_id set" do
    @coinstats_account.update!(
      account_id: nil,
      raw_transactions_payload: [
        {
          type: "Received",
          date: "2025-01-15T10:00:00.000Z",
          coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
          hash: { id: "0xnofilter1" }
        },
        {
          type: "Received",
          date: "2025-01-16T10:00:00.000Z",
          coinData: { count: 100, symbol: "USDC", currentValue: 100 },
          hash: { id: "0xnofilter2" }
        }
      ]
    )

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    assert_difference "Entry.count", 2 do
      result = processor.process
      assert result[:success]
      assert_equal 2, result[:total]
    end
  end

  test "tracks failed transactions with errors" do
    @coinstats_account.update!(
      account_id: nil,
      raw_transactions_payload: [
        {
          type: "Received",
          date: "2025-01-15T10:00:00.000Z",
          coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
          hash: { id: "0xvalid1" }
        },
        {
          # Missing date
          type: "Received",
          coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
          hash: { id: "0xinvalid" }
        }
      ]
    )

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    result = processor.process

    refute result[:success]
    assert_equal 2, result[:total]
    assert_equal 1, result[:imported]
    assert_equal 1, result[:failed]
    assert_equal 1, result[:errors].count

    error = result[:errors].first
    assert_equal "0xinvalid", error[:transaction_id]
    assert_match(/Validation error/, error[:error])
  end

  # Tests for strict symbol matching to avoid false positives
  # (e.g., "ETH" should not match "Ethereum Classic" which has symbol "ETC")

  test "symbol matching does not cause false positives with similar names" do
    # Ethereum Classic wallet should NOT match ETH transactions
    @coinstats_account.update!(
      name: "Ethereum Classic (0x1234abcd...)",
      account_id: "ethereum-classic",
      raw_transactions_payload: [
        {
          type: "Received",
          date: "2025-01-15T10:00:00.000Z",
          coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
          hash: { id: "0xfalsepositive1" }
          # No coin.id, relies on symbol matching fallback
        }
      ]
    )

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    # Should NOT process - "ETH" should not match "Ethereum Classic"
    assert_no_difference "Entry.count" do
      result = processor.process
      assert result[:success]
      assert_equal 0, result[:total]
    end
  end

  test "symbol matching works with parenthesized token format" do
    @coinstats_account.update!(
      name: "Ethereum (ETH)",
      account_id: "ethereum",
      raw_transactions_payload: [
        {
          type: "Received",
          date: "2025-01-15T10:00:00.000Z",
          coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
          hash: { id: "0xparenthesized1" }
        }
      ]
    )

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    assert_difference "Entry.count", 1 do
      result = processor.process
      assert result[:success]
    end
  end

  test "symbol matching works with symbol as whole word in name" do
    @coinstats_account.update!(
      name: "ETH Wallet",
      account_id: "ethereum",
      raw_transactions_payload: [
        {
          type: "Received",
          date: "2025-01-15T10:00:00.000Z",
          coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
          hash: { id: "0xwholeword1" }
        }
      ]
    )

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    assert_difference "Entry.count", 1 do
      result = processor.process
      assert result[:success]
    end
  end

  test "symbol matching does not match partial substrings" do
    # WETH wallet should NOT match ETH transactions via symbol fallback
    @coinstats_account.update!(
      name: "WETH Wrapped Ethereum",
      account_id: "weth",
      raw_transactions_payload: [
        {
          type: "Received",
          date: "2025-01-15T10:00:00.000Z",
          coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
          hash: { id: "0xpartial1" }
          # No coin.id, relies on symbol matching fallback
        }
      ]
    )

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    # Should NOT process - "ETH" is a substring of "WETH" but not a whole word match
    assert_no_difference "Entry.count" do
      result = processor.process
      assert result[:success]
      assert_equal 0, result[:total]
    end
  end

  test "symbol matching is case insensitive" do
    @coinstats_account.update!(
      name: "eth wallet",
      account_id: "ethereum",
      raw_transactions_payload: [
        {
          type: "Received",
          date: "2025-01-15T10:00:00.000Z",
          coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
          hash: { id: "0xcaseinsensitive1" }
        }
      ]
    )

    processor = CoinstatsAccount::Transactions::Processor.new(@coinstats_account)

    assert_difference "Entry.count", 1 do
      result = processor.process
      assert result[:success]
    end
  end
end
