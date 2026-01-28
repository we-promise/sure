require "test_helper"

class CoinstatsEntry::ProcessorTest < ActiveSupport::TestCase
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
      name: "Test Crypto Account",
      balance: 1000,
      currency: "USD"
    )
    @coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Test ETH Wallet",
      currency: "USD",
      current_balance: 5000,
      institution_metadata: { "logo" => "https://example.com/eth.png" }
    )
    AccountProvider.create!(account: @account, provider: @coinstats_account)
  end

  test "processes received transaction" do
    transaction_data = {
      type: "Received",
      date: "2025-01-15T10:00:00.000Z",
      coinData: { count: 1.5, symbol: "ETH", currentValue: 3000 },
      hash: { id: "0xabc123", explorerUrl: "https://etherscan.io/tx/0xabc123" }
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)

    assert_difference "Entry.count", 1 do
      processor.process
    end

    entry = @account.entries.last
    assert_equal "coinstats_0xabc123", entry.external_id
    assert_equal BigDecimal("-3000"), entry.amount # Negative = income
    assert_equal "USD", entry.currency
    assert_equal Date.new(2025, 1, 15), entry.date
    assert_equal "Received ETH", entry.name
  end

  test "processes sent transaction" do
    transaction_data = {
      type: "Sent",
      date: "2025-01-15T10:00:00.000Z",
      coinData: { count: -0.5, symbol: "ETH", currentValue: 1000 },
      hash: { id: "0xdef456", explorerUrl: "https://etherscan.io/tx/0xdef456" }
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)

    assert_difference "Entry.count", 1 do
      processor.process
    end

    entry = @account.entries.last
    assert_equal BigDecimal("1000"), entry.amount # Positive = expense
    assert_equal "Sent ETH", entry.name
  end

  test "stores extra metadata" do
    transaction_data = {
      type: "Received",
      date: "2025-01-15T10:00:00.000Z",
      coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
      hash: { id: "0xmeta123", explorerUrl: "https://etherscan.io/tx/0xmeta123" },
      profitLoss: { profit: 100.50, profitPercent: 5.25 },
      fee: { count: 0.001, coin: { symbol: "ETH" }, totalWorth: 2.0 }
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)
    processor.process

    entry = @account.entries.last
    extra = entry.transaction.extra["coinstats"]

    assert_equal "0xmeta123", extra["transaction_hash"]
    assert_equal "https://etherscan.io/tx/0xmeta123", extra["explorer_url"]
    assert_equal "Received", extra["transaction_type"]
    assert_equal "ETH", extra["symbol"]
    assert_equal 1.0, extra["count"]
    assert_equal 100.50, extra["profit"]
    assert_equal 5.25, extra["profit_percent"]
    assert_equal 0.001, extra["fee_amount"]
    assert_equal "ETH", extra["fee_symbol"]
    assert_equal 2.0, extra["fee_usd"]
  end

  test "handles UTXO transaction ID format" do
    transaction_data = {
      type: "Received",
      date: "2025-01-15T10:00:00.000Z",
      coinData: { count: 0.1, symbol: "BTC", currentValue: 4000 },
      transactions: [
        { items: [ { id: "utxo_tx_id_123" } ] }
      ]
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)
    processor.process

    entry = @account.entries.last
    assert_equal "coinstats_utxo_tx_id_123", entry.external_id
  end

  test "generates fallback ID when no hash available" do
    transaction_data = {
      type: "Swap",
      date: "2025-01-15T10:00:00.000Z",
      coinData: { count: 100, symbol: "USDC", currentValue: 100 }
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)
    processor.process

    entry = @account.entries.last
    # Fallback IDs use a hash digest format: "coinstats_fallback_<16-char-hex>"
    assert_match(/^coinstats_fallback_[a-f0-9]{16}$/, entry.external_id)
  end

  test "raises error when transaction missing identifier" do
    transaction_data = {
      type: nil,
      date: nil,
      coinData: { count: nil }
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)

    assert_raises(ArgumentError) do
      processor.process
    end
  end

  test "skips processing when no linked account" do
    unlinked_account = @coinstats_item.coinstats_accounts.create!(
      name: "Unlinked",
      currency: "USD"
    )

    transaction_data = {
      type: "Received",
      date: "2025-01-15T10:00:00.000Z",
      coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
      hash: { id: "0xskip123" }
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: unlinked_account)

    assert_no_difference "Entry.count" do
      result = processor.process
      assert_nil result
    end
  end

  test "creates notes with transaction details" do
    transaction_data = {
      type: "Received",
      date: "2025-01-15T10:00:00.000Z",
      coinData: { count: 1.5, symbol: "ETH", currentValue: 3000 },
      hash: { id: "0xnotes123", explorerUrl: "https://etherscan.io/tx/0xnotes123" },
      profitLoss: { profit: 150.00, profitPercent: 10.0 },
      fee: { count: 0.002, coin: { symbol: "ETH" }, totalWorth: 4.0 }
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)
    processor.process

    entry = @account.entries.last
    assert_includes entry.notes, "1.5 ETH"
    assert_includes entry.notes, "Fee: 0.002 ETH"
    assert_includes entry.notes, "P/L: $150.0 (10.0%)"
    assert_includes entry.notes, "Explorer: https://etherscan.io/tx/0xnotes123"
  end

  test "handles integer timestamp" do
    timestamp = Time.new(2025, 1, 15, 10, 0, 0).to_i

    transaction_data = {
      type: "Received",
      date: timestamp,
      coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
      hash: { id: "0xtimestamp123" }
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)
    processor.process

    entry = @account.entries.last
    assert_equal Date.new(2025, 1, 15), entry.date
  end

  test "raises error for missing date" do
    transaction_data = {
      type: "Received",
      coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
      hash: { id: "0xnodate123" }
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)

    assert_raises(ArgumentError) do
      processor.process
    end
  end

  test "builds name with symbol preferring it over coin name" do
    transaction_data = {
      type: "Received",
      date: "2025-01-15T10:00:00.000Z",
      coinData: { count: 1.0, symbol: "WETH" },
      hash: { id: "0xname123" },
      profitLoss: { currentValue: 2000 },
      transactions: [
        { items: [ { coin: { name: "Wrapped Ether" } } ] }
      ]
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)
    processor.process

    entry = @account.entries.last
    assert_equal "Received WETH", entry.name
  end

  test "handles swap out as outgoing transaction" do
    transaction_data = {
      type: "swap_out",
      date: "2025-01-15T10:00:00.000Z",
      coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
      hash: { id: "0xswap123" }
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)
    processor.process

    entry = @account.entries.last
    assert_equal BigDecimal("2000"), entry.amount # Positive = expense/outflow
  end

  test "is idempotent - does not duplicate transactions" do
    transaction_data = {
      type: "Received",
      date: "2025-01-15T10:00:00.000Z",
      coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
      hash: { id: "0xidempotent123" }
    }

    processor = CoinstatsEntry::Processor.new(transaction_data, coinstats_account: @coinstats_account)

    assert_difference "Entry.count", 1 do
      processor.process
    end

    # Processing again should not create duplicate
    assert_no_difference "Entry.count" do
      processor.process
    end
  end
end
