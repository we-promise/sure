require "test_helper"

class CoinstatsItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @coinstats_item = CoinstatsItem.create!(
      family: @family,
      name: "Test CoinStats Connection",
      api_key: "test_api_key_123"
    )

    @mock_provider = mock("Provider::Coinstats")
  end

  test "returns early when no linked accounts" do
    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)

    result = importer.import

    assert result[:success]
    assert_equal 0, result[:accounts_updated]
    assert_equal 0, result[:transactions_imported]
  end

  test "updates linked accounts with balance data" do
    # Create a linked coinstats account
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Ethereum",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Ethereum Wallet",
      currency: "USD",
      raw_payload: { address: "0x123abc", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    # Mock balance response
    balance_data = [
      { coinId: "ethereum", name: "Ethereum", symbol: "ETH", amount: 1.5, price: 2000, imgUrl: "https://example.com/eth.png" }
    ]

    @mock_provider.expects(:get_wallet_balance)
      .with("0x123abc", "ethereum")
      .returns(balance_data)

    @mock_provider.expects(:get_wallet_transactions)
      .with("0x123abc", "ethereum")
      .returns({ result: [] })

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)
    result = importer.import

    assert result[:success]
    assert_equal 1, result[:accounts_updated]
    assert_equal 0, result[:accounts_failed]
  end

  test "skips account when missing address or blockchain" do
    # Create a linked account with missing wallet info
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Crypto",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Missing Info Wallet",
      currency: "USD",
      raw_payload: {} # Missing address and blockchain
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)
    result = importer.import

    # The import succeeds but no accounts are updated (missing info returns success: false)
    assert result[:success] # No exceptions = success
    assert_equal 0, result[:accounts_updated]
    assert_equal 0, result[:accounts_failed] # Doesn't count as "failed" - only exceptions do
  end

  test "imports transactions and merges with existing" do
    # Create a linked coinstats account with existing transactions
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Ethereum",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Ethereum Wallet",
      currency: "USD",
      raw_payload: { address: "0x123abc", blockchain: "ethereum" },
      raw_transactions_payload: [
        { hash: { id: "0xexisting1" }, type: "Received", date: "2025-01-01T10:00:00.000Z" }
      ]
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    balance_data = [
      { coinId: "ethereum", name: "Ethereum", symbol: "ETH", amount: 2.0, price: 2500 }
    ]

    transactions_data = {
      result: [
        { hash: { id: "0xexisting1" }, type: "Received", date: "2025-01-01T10:00:00.000Z" }, # duplicate
        { hash: { id: "0xnew1" }, type: "Sent", date: "2025-01-02T11:00:00.000Z" } # new
      ]
    }

    @mock_provider.expects(:get_wallet_balance)
      .with("0x123abc", "ethereum")
      .returns(balance_data)

    @mock_provider.expects(:get_wallet_transactions)
      .with("0x123abc", "ethereum")
      .returns(transactions_data)

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)
    result = importer.import

    assert result[:success]
    assert_equal 1, result[:accounts_updated]

    # Should have 2 transactions (1 existing + 1 new, no duplicate)
    coinstats_account.reload
    assert_equal 2, coinstats_account.raw_transactions_payload.count
  end

  test "handles rate limit error during transactions fetch gracefully" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Test Ethereum",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Ethereum Wallet",
      currency: "USD",
      raw_payload: { address: "0x123abc", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    balance_data = [
      { coinId: "ethereum", name: "Ethereum", symbol: "ETH", amount: 1.0, price: 2000 }
    ]

    @mock_provider.expects(:get_wallet_balance)
      .with("0x123abc", "ethereum")
      .returns(balance_data)

    @mock_provider.expects(:get_wallet_transactions)
      .with("0x123abc", "ethereum")
      .raises(Provider::Coinstats::RateLimitError.new("Rate limited"))

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)
    result = importer.import

    # Should still succeed since balance was updated
    assert result[:success]
    assert_equal 1, result[:accounts_updated]
    assert_equal 0, result[:transactions_imported]
  end

  test "calculates balance from matching token only, not all tokens" do
    # Create two accounts for different tokens in the same wallet
    crypto1 = Crypto.create!
    account1 = @family.accounts.create!(
      accountable: crypto1,
      name: "Ethereum (0xmu...ulti)",
      balance: 0,
      currency: "USD"
    )
    coinstats_account1 = @coinstats_item.coinstats_accounts.create!(
      name: "Ethereum (0xmu...ulti)",
      currency: "USD",
      account_id: "ethereum",
      raw_payload: { address: "0xmulti", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account1, provider: coinstats_account1)

    crypto2 = Crypto.create!
    account2 = @family.accounts.create!(
      accountable: crypto2,
      name: "Dai Stablecoin (0xmu...ulti)",
      balance: 0,
      currency: "USD"
    )
    coinstats_account2 = @coinstats_item.coinstats_accounts.create!(
      name: "Dai Stablecoin (0xmu...ulti)",
      currency: "USD",
      account_id: "dai",
      raw_payload: { address: "0xmulti", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account2, provider: coinstats_account2)

    # Multiple tokens with different values
    balance_data = [
      { coinId: "ethereum", name: "Ethereum", symbol: "ETH", amount: 2.0, price: 2000 }, # $4000
      { coinId: "dai", name: "Dai Stablecoin", symbol: "DAI", amount: 1000, price: 1 }   # $1000
    ]

    @mock_provider.expects(:get_wallet_balance)
      .with("0xmulti", "ethereum")
      .returns(balance_data)
      .twice

    @mock_provider.expects(:get_wallet_transactions)
      .with("0xmulti", "ethereum")
      .returns({ result: [] })
      .twice

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)
    importer.import

    coinstats_account1.reload
    coinstats_account2.reload

    # Each account should have only its matching token's balance, not the total
    # ETH: 2.0 * 2000 = $4000
    assert_equal 4000.0, coinstats_account1.current_balance.to_f
    # DAI: 1000 * 1 = $1000
    assert_equal 1000.0, coinstats_account2.current_balance.to_f
  end

  test "handles api errors for individual accounts without failing entire import" do
    crypto1 = Crypto.create!
    account1 = @family.accounts.create!(
      accountable: crypto1,
      name: "Working Wallet",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account1 = @coinstats_item.coinstats_accounts.create!(
      name: "Working Wallet",
      currency: "USD",
      raw_payload: { address: "0xworking", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account1, provider: coinstats_account1)

    crypto2 = Crypto.create!
    account2 = @family.accounts.create!(
      accountable: crypto2,
      name: "Failing Wallet",
      balance: 500,
      currency: "USD"
    )
    coinstats_account2 = @coinstats_item.coinstats_accounts.create!(
      name: "Failing Wallet",
      currency: "USD",
      raw_payload: { address: "0xfailing", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account2, provider: coinstats_account2)

    # First account succeeds
    @mock_provider.expects(:get_wallet_balance)
      .with("0xworking", "ethereum")
      .returns([ { coinId: "ethereum", name: "Ethereum", amount: 1.0, price: 2000 } ])

    @mock_provider.expects(:get_wallet_transactions)
      .with("0xworking", "ethereum")
      .returns({ result: [] })

    # Second account fails
    @mock_provider.expects(:get_wallet_balance)
      .with("0xfailing", "ethereum")
      .raises(StandardError.new("API Error"))

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)
    result = importer.import

    refute result[:success] # Overall not successful because one failed
    assert_equal 1, result[:accounts_updated]
    assert_equal 1, result[:accounts_failed]
  end
end
