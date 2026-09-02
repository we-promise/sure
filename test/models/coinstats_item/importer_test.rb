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
    # Stub DeFi endpoint globally — individual tests override if needed
    @mock_provider.stubs(:get_wallet_defi).returns(success_response({ protocols: [] }))
  end

  # Helper to wrap data in Provider::Response
  def success_response(data)
    Provider::Response.new(success?: true, data: data, error: nil)
  end

  def error_response(message)
    Provider::Response.new(success?: false, data: nil, error: Provider::Error.new(message))
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

    bulk_response = [
      { blockchain: "ethereum", address: "0x123abc", connectionId: "ethereum", balances: balance_data }
    ]

    @mock_provider.expects(:get_wallet_balances)
      .with("ethereum:0x123abc")
      .returns(success_response(bulk_response))

    @mock_provider.expects(:extract_wallet_balance)
      .with(bulk_response, "0x123abc", "ethereum")
      .returns(balance_data)

    bulk_transactions_response = [
      { blockchain: "ethereum", address: "0x123abc", connectionId: "ethereum", transactions: [] }
    ]

    @mock_provider.expects(:get_wallet_transactions)
      .with("ethereum:0x123abc")
      .returns(success_response(bulk_transactions_response))

    @mock_provider.expects(:extract_wallet_transactions)
      .with(bulk_transactions_response, "0x123abc", "ethereum")
      .returns([])

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
      account_id: "ethereum",
      raw_payload: { address: "0x123abc", blockchain: "ethereum" },
      raw_transactions_payload: [
        { hash: { id: "0xexisting1" }, type: "Received", date: "2025-01-01T10:00:00.000Z", transactions: [ { items: [ { coin: { id: "ethereum" } } ] } ] }
      ]
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    balance_data = [
      { coinId: "ethereum", name: "Ethereum", symbol: "ETH", amount: 2.0, price: 2500 }
    ]

    bulk_response = [
      { blockchain: "ethereum", address: "0x123abc", connectionId: "ethereum", balances: balance_data }
    ]

    @mock_provider.expects(:get_wallet_balances)
      .with("ethereum:0x123abc")
      .returns(success_response(bulk_response))

    @mock_provider.expects(:extract_wallet_balance)
      .with(bulk_response, "0x123abc", "ethereum")
      .returns(balance_data)

    new_transactions = [
      { hash: { id: "0xexisting1" }, type: "Received", date: "2025-01-01T10:00:00.000Z", transactions: [ { items: [ { coin: { id: "ethereum" } } ] } ] }, # duplicate
      { hash: { id: "0xnew1" }, type: "Sent", date: "2025-01-02T11:00:00.000Z", transactions: [ { items: [ { coin: { id: "ethereum" } } ] } ] } # new
    ]

    bulk_transactions_response = [
      { blockchain: "ethereum", address: "0x123abc", connectionId: "ethereum", transactions: new_transactions }
    ]

    @mock_provider.expects(:get_wallet_transactions)
      .with("ethereum:0x123abc")
      .returns(success_response(bulk_transactions_response))

    @mock_provider.expects(:extract_wallet_transactions)
      .with(bulk_transactions_response, "0x123abc", "ethereum")
      .returns(new_transactions)

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)
    result = importer.import

    assert result[:success]
    assert_equal 1, result[:accounts_updated]

    # Should have 2 transactions (1 existing + 1 new, no duplicate)
    coinstats_account.reload
    assert_equal 2, coinstats_account.raw_transactions_payload.count
  end

  test "bails and preserves wallet snapshot when transactions fetch is rate limited" do
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
      current_balance: 1000,
      raw_payload: { address: "0x123abc", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    balance_data = [
      { coinId: "ethereum", name: "Ethereum", symbol: "ETH", amount: 1.0, price: 2000 }
    ]

    bulk_response = [
      { blockchain: "ethereum", address: "0x123abc", connectionId: "ethereum", balances: balance_data }
    ]

    @mock_provider.expects(:get_wallet_balances)
      .with("ethereum:0x123abc")
      .returns(success_response(bulk_response))

    @mock_provider.expects(:extract_wallet_balance).never

    @mock_provider.expects(:get_wallet_transactions)
      .with("ethereum:0x123abc")
      .raises(Provider::Coinstats::RateLimitError.new("Rate limited"))

    @mock_provider.expects(:extract_wallet_transactions).never

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)

    assert_no_changes -> { coinstats_account.reload.current_balance.to_f } do
      result = importer.import

      refute result[:success]
      assert_equal 0, result[:accounts_updated]
      assert_equal 1, result[:accounts_failed]
      assert_equal 0, result[:transactions_imported]
    end
  end

  test "preserves exchange portfolio snapshot when portfolio coin fetch is missing" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Bitvavo",
      balance: 250,
      cash_balance: 10,
      currency: "EUR"
    )

    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Bitvavo",
      currency: "EUR",
      account_id: "exchange_portfolio:portfolio_123",
      wallet_address: "portfolio_123",
      current_balance: 250,
      raw_payload: {
        source: "exchange",
        portfolio_account: true,
        portfolio_id: "portfolio_123",
        connection_id: "bitvavo",
        exchange_name: "Bitvavo",
        coins: [
          {
            coin: { identifier: "bitcoin", symbol: "BTC", name: "Bitcoin" },
            count: "0.003",
            price: { EUR: "80000" }
          },
          {
            coin: { identifier: "FiatCoin:eur", symbol: "EUR", name: "Euro", isFiat: true },
            count: "10",
            price: { EUR: "1" }
          }
        ]
      },
      raw_transactions_payload: []
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    @mock_provider.expects(:sync_exchange).with(portfolio_id: "portfolio_123").returns(success_response({}))
    @mock_provider.expects(:list_exchange_transactions)
      .with(portfolio_id: "portfolio_123", currency: "USD", from: nil)
      .returns([])
    @mock_provider.expects(:list_portfolio_coins)
      .with(portfolio_id: "portfolio_123")
      .returns(nil)

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)

    assert_no_changes -> { coinstats_account.reload.current_balance.to_f } do
      result = importer.import
      assert result[:success]
      assert_equal 1, result[:accounts_updated]
      assert_equal 0, result[:transactions_imported]
    end

    reloaded = coinstats_account.reload
    assert_equal "portfolio_123", reloaded.raw_payload["portfolio_id"]
    assert_equal 2, reloaded.raw_payload["coins"].size
    assert_equal 250.0, reloaded.current_balance.to_f
  end

  test "writes an empty exchange portfolio snapshot when CoinStats returns an empty portfolio" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Bitvavo",
      balance: 250,
      cash_balance: 10,
      currency: "EUR"
    )

    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Bitvavo",
      currency: "EUR",
      account_id: "exchange_portfolio:portfolio_123",
      wallet_address: "portfolio_123",
      current_balance: 250,
      raw_payload: {
        source: "exchange",
        portfolio_account: true,
        portfolio_id: "portfolio_123",
        connection_id: "bitvavo",
        exchange_name: "Bitvavo",
        coins: [
          {
            coin: { identifier: "bitcoin", symbol: "BTC", name: "Bitcoin" },
            count: "0.003",
            price: { EUR: "80000" }
          }
        ]
      },
      raw_transactions_payload: []
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    @mock_provider.expects(:sync_exchange).with(portfolio_id: "portfolio_123").returns(success_response({}))
    @mock_provider.expects(:list_exchange_transactions)
      .with(portfolio_id: "portfolio_123", currency: "USD", from: nil)
      .returns([])
    @mock_provider.expects(:list_portfolio_coins)
      .with(portfolio_id: "portfolio_123")
      .returns([])

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)
    result = importer.import

    assert result[:success]
    assert_equal 1, result[:accounts_updated]

    reloaded = coinstats_account.reload
    assert_equal 0.0, reloaded.current_balance.to_f
    assert_equal [], reloaded.raw_payload["coins"]
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

    # Both accounts share the same wallet address/blockchain, so only one unique wallet
    bulk_response = [
      { blockchain: "ethereum", address: "0xmulti", connectionId: "ethereum", balances: balance_data }
    ]

    @mock_provider.expects(:get_wallet_balances)
      .with("ethereum:0xmulti")
      .returns(success_response(bulk_response))

    @mock_provider.expects(:extract_wallet_balance)
      .with(bulk_response, "0xmulti", "ethereum")
      .returns(balance_data)
      .twice

    bulk_transactions_response = [
      { blockchain: "ethereum", address: "0xmulti", connectionId: "ethereum", transactions: [] }
    ]

    @mock_provider.expects(:get_wallet_transactions)
      .with("ethereum:0xmulti")
      .returns(success_response(bulk_transactions_response))

    @mock_provider.expects(:extract_wallet_transactions)
      .with(bulk_transactions_response, "0xmulti", "ethereum")
      .returns([])
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

    # With multiple wallets, bulk endpoint is used
    # Bulk response includes only the working wallet's data
    bulk_response = [
      {
        blockchain: "ethereum",
        address: "0xworking",
        connectionId: "ethereum",
        balances: [ { coinId: "ethereum", name: "Ethereum", amount: 1.0, price: 2000 } ]
      }
      # 0xfailing not included - simulates partial failure or missing data
    ]

    @mock_provider.expects(:get_wallet_balances)
      .with("ethereum:0xfailing,ethereum:0xworking")
      .returns(success_response(bulk_response))

    @mock_provider.expects(:extract_wallet_balance)
      .with(bulk_response, "0xworking", "ethereum")
      .returns([ { coinId: "ethereum", name: "Ethereum", amount: 1.0, price: 2000 } ])

    bulk_transactions_response = [
      {
        blockchain: "ethereum",
        address: "0xworking",
        connectionId: "ethereum",
        transactions: []
      }
    ]

    @mock_provider.expects(:get_wallet_transactions)
      .with("ethereum:0xfailing,ethereum:0xworking")
      .returns(success_response(bulk_transactions_response))

    @mock_provider.expects(:extract_wallet_transactions)
      .with(bulk_transactions_response, "0xworking", "ethereum")
      .returns([])

    @mock_provider.expects(:extract_wallet_transactions)
      .with(bulk_transactions_response, "0xfailing", "ethereum")
      .returns([])

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)
    result = importer.import

    assert result[:success] # Both accounts updated (one with empty balance)
    assert_equal 2, result[:accounts_updated]
    assert_equal 0, result[:accounts_failed]
  end

  test "multi-wallet import preserves an existing wallet when bulk response omits it" do
    crypto1 = Crypto.create!
    account1 = @family.accounts.create!(
      accountable: crypto1,
      name: "Working Wallet",
      balance: 2000,
      currency: "USD"
    )
    coinstats_account1 = @coinstats_item.coinstats_accounts.create!(
      name: "Working Wallet",
      currency: "USD",
      current_balance: 2000,
      account_id: "ethereum",
      raw_payload: {
        address: "0xworking",
        blockchain: "ethereum",
        coinId: "ethereum",
        amount: 1.0,
        price: 2000,
        balance: 2000
      }
    )
    AccountProvider.create!(account: account1, provider: coinstats_account1)

    crypto2 = Crypto.create!
    account2 = @family.accounts.create!(
      accountable: crypto2,
      name: "DOGE Wallet",
      balance: 100,
      currency: "USD"
    )
    coinstats_account2 = @coinstats_item.coinstats_accounts.create!(
      name: "DOGE Wallet",
      currency: "USD",
      current_balance: 100,
      account_id: "dogecoin",
      raw_payload: {
        address: "Ddoge123",
        blockchain: "dogecoin",
        coinId: "dogecoin",
        amount: 1000,
        price: 0.1,
        balance: 100
      }
    )
    AccountProvider.create!(account: account2, provider: coinstats_account2)

    bulk_response = [
      {
        blockchain: "dogecoin",
        address: "Ddoge123",
        connectionId: "dogecoin",
        balances: [ { coinId: "dogecoin", name: "Dogecoin", amount: 1000, price: 0.1 } ]
      }
    ]

    @mock_provider.expects(:get_wallet_balances)
      .with("dogecoin:Ddoge123,ethereum:0xworking")
      .returns(success_response(bulk_response))

    @mock_provider.expects(:extract_wallet_balance)
      .with(bulk_response, "Ddoge123", "dogecoin")
      .returns([ { coinId: "dogecoin", name: "Dogecoin", amount: 1000, price: 0.1 } ])

    bulk_transactions_response = [
      {
        blockchain: "dogecoin",
        address: "Ddoge123",
        connectionId: "dogecoin",
        transactions: []
      }
    ]

    @mock_provider.expects(:get_wallet_transactions)
      .with("dogecoin:Ddoge123,ethereum:0xworking")
      .returns(success_response(bulk_transactions_response))

    @mock_provider.expects(:extract_wallet_transactions)
      .with(bulk_transactions_response, "0xworking", "ethereum")
      .returns([])

    @mock_provider.expects(:extract_wallet_transactions)
      .with(bulk_transactions_response, "Ddoge123", "dogecoin")
      .returns([])

    assert_difference "DebugLogEntry.count", 1 do
      result = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider).import

      assert result[:success]
    end

    coinstats_account1.reload
    coinstats_account2.reload

    assert_equal 2000.0, coinstats_account1.current_balance.to_f, "missing wallet data should not zero an existing wallet"
    assert_equal 100.0, coinstats_account2.current_balance.to_f

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "provider_sync_error", entry.category
    assert_equal "warn", entry.level
    assert_equal "CoinStats wallet balance sync preserved existing snapshot because wallet was missing from bulk response", entry.message
    assert_equal "coinstats", entry.provider_key
    assert_equal @family.id, entry.family_id
    assert_equal coinstats_account1.account_provider.id, entry.account_provider_id
    assert_equal "wallet_missing_from_bulk_response", entry.metadata["reason"]
    assert_equal "0xworking", entry.metadata["wallet_address"]
  end

  test "bulk balance fetch failure preserves all existing wallet balances during import" do
    crypto1 = Crypto.create!
    account1 = @family.accounts.create!(
      accountable: crypto1,
      name: "Ethereum Wallet",
      balance: 2000,
      currency: "USD"
    )
    coinstats_account1 = @coinstats_item.coinstats_accounts.create!(
      name: "Ethereum Wallet",
      currency: "USD",
      current_balance: 2000,
      account_id: "ethereum",
      raw_payload: {
        address: "0xeth123",
        blockchain: "ethereum",
        coinId: "ethereum",
        amount: 1.0,
        price: 2000,
        balance: 2000
      }
    )
    AccountProvider.create!(account: account1, provider: coinstats_account1)

    crypto2 = Crypto.create!
    account2 = @family.accounts.create!(
      accountable: crypto2,
      name: "DOGE Wallet",
      balance: 100,
      currency: "USD"
    )
    coinstats_account2 = @coinstats_item.coinstats_accounts.create!(
      name: "DOGE Wallet",
      currency: "USD",
      current_balance: 100,
      account_id: "dogecoin",
      raw_payload: {
        address: "Ddoge456",
        blockchain: "dogecoin",
        coinId: "dogecoin",
        amount: 1000,
        price: 0.1,
        balance: 100
      }
    )
    AccountProvider.create!(account: account2, provider: coinstats_account2)

    @mock_provider.expects(:get_wallet_balances)
      .with("dogecoin:Ddoge456,ethereum:0xeth123")
      .raises(Provider::Coinstats::Error.new("CoinStats timeout"))

    bulk_transactions_response = []
    @mock_provider.expects(:get_wallet_transactions)
      .with("dogecoin:Ddoge456,ethereum:0xeth123")
      .returns(success_response(bulk_transactions_response))

    assert_difference "DebugLogEntry.count", 3 do
      result = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider).import

      assert result[:success]
    end

    coinstats_account1.reload
    coinstats_account2.reload

    assert_equal 2000.0, coinstats_account1.current_balance.to_f
    assert_equal 100.0, coinstats_account2.current_balance.to_f

    entries = DebugLogEntry.order(:created_at).last(3)
    fetch_failure_entry = entries.find { |entry| entry.message == "CoinStats bulk balance fetch failed" }
    assert_not_nil fetch_failure_entry
    assert_equal "provider_sync_error", fetch_failure_entry.category
    assert_equal "coinstats", fetch_failure_entry.provider_key
    assert_equal "CoinStats timeout", fetch_failure_entry.metadata["error_message"]

    preserved_entries = entries.select { |entry| entry.message == "CoinStats wallet balance sync preserved existing snapshot after bulk fetch failure" }
    assert_equal 2, preserved_entries.size
    assert_equal [ "0xeth123", "Ddoge456" ], preserved_entries.map { |entry| entry.metadata["wallet_address"] }.sort
  end

  test "uses bulk endpoint for multiple unique wallets and falls back on error" do
    # Create accounts with two different wallet addresses
    crypto1 = Crypto.create!
    account1 = @family.accounts.create!(
      accountable: crypto1,
      name: "Ethereum Wallet",
      balance: 0,
      currency: "USD"
    )
    coinstats_account1 = @coinstats_item.coinstats_accounts.create!(
      name: "Ethereum Wallet",
      currency: "USD",
      raw_payload: { address: "0xeth123", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account1, provider: coinstats_account1)

    crypto2 = Crypto.create!
    account2 = @family.accounts.create!(
      accountable: crypto2,
      name: "Bitcoin Wallet",
      balance: 0,
      currency: "USD"
    )
    coinstats_account2 = @coinstats_item.coinstats_accounts.create!(
      name: "Bitcoin Wallet",
      currency: "USD",
      raw_payload: { address: "bc1qbtc456", blockchain: "bitcoin" }
    )
    AccountProvider.create!(account: account2, provider: coinstats_account2)

    # Bulk endpoint returns data for both wallets
    bulk_response = [
      {
        blockchain: "ethereum",
        address: "0xeth123",
        connectionId: "ethereum",
        balances: [ { coinId: "ethereum", name: "Ethereum", amount: 2.0, price: 2500 } ]
      },
      {
        blockchain: "bitcoin",
        address: "bc1qbtc456",
        connectionId: "bitcoin",
        balances: [ { coinId: "bitcoin", name: "Bitcoin", amount: 0.1, price: 45000 } ]
      }
    ]

    @mock_provider.expects(:get_wallet_balances)
      .with("bitcoin:bc1qbtc456,ethereum:0xeth123")
      .returns(success_response(bulk_response))

    @mock_provider.expects(:extract_wallet_balance)
      .with(bulk_response, "0xeth123", "ethereum")
      .returns([ { coinId: "ethereum", name: "Ethereum", amount: 2.0, price: 2500 } ])

    @mock_provider.expects(:extract_wallet_balance)
      .with(bulk_response, "bc1qbtc456", "bitcoin")
      .returns([ { coinId: "bitcoin", name: "Bitcoin", amount: 0.1, price: 45000 } ])

    bulk_transactions_response = [
      {
        blockchain: "ethereum",
        address: "0xeth123",
        connectionId: "ethereum",
        transactions: []
      },
      {
        blockchain: "bitcoin",
        address: "bc1qbtc456",
        connectionId: "bitcoin",
        transactions: []
      }
    ]

    @mock_provider.expects(:get_wallet_transactions)
      .with("bitcoin:bc1qbtc456,ethereum:0xeth123")
      .returns(success_response(bulk_transactions_response))

    @mock_provider.expects(:extract_wallet_transactions)
      .with(bulk_transactions_response, "0xeth123", "ethereum")
      .returns([])

    @mock_provider.expects(:extract_wallet_transactions)
      .with(bulk_transactions_response, "bc1qbtc456", "bitcoin")
      .returns([])

    importer = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider)
    result = importer.import

    assert result[:success]
    assert_equal 2, result[:accounts_updated]

    # Verify balances were updated
    coinstats_account1.reload
    coinstats_account2.reload
    assert_equal 5000.0, coinstats_account1.current_balance.to_f  # 2.0 * 2500
    assert_equal 4500.0, coinstats_account2.current_balance.to_f  # 0.1 * 45000
  end

  # DeFi / staking tests

  test "skips DeFi sync for unsupported blockchains" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Bitcoin Wallet",
      balance: 4500,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Bitcoin Wallet",
      currency: "USD",
      account_id: "bitcoin",
      raw_payload: { address: "bc1qbtc456", blockchain: "bitcoin" }
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    balance_data = [
      { coinId: "bitcoin", name: "Bitcoin", symbol: "BTC", amount: 0.1, price: 45000 }
    ]
    bulk_response = [
      { blockchain: "bitcoin", address: "bc1qbtc456", connectionId: "bitcoin", balances: balance_data }
    ]
    bulk_transactions_response = [
      { blockchain: "bitcoin", address: "bc1qbtc456", connectionId: "bitcoin", transactions: [] }
    ]

    @mock_provider.expects(:get_wallet_defi).never
    @mock_provider.expects(:get_wallet_balances)
      .with("bitcoin:bc1qbtc456")
      .returns(success_response(bulk_response))
    @mock_provider.expects(:extract_wallet_balance)
      .with(bulk_response, "bc1qbtc456", "bitcoin")
      .returns(balance_data)
    @mock_provider.expects(:get_wallet_transactions)
      .with("bitcoin:bc1qbtc456")
      .returns(success_response(bulk_transactions_response))
    @mock_provider.expects(:extract_wallet_transactions)
      .with(bulk_transactions_response, "bc1qbtc456", "bitcoin")
      .returns([])

    result = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider).import

    assert result[:success]
    assert_equal 1, result[:accounts_updated]
    assert_equal 4500.0, coinstats_account.reload.current_balance.to_f
  end

  test "creates DeFi account with balance equal to total position value, not quantity * price" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Ethereum Wallet",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Ethereum (0x12...abc)",
      currency: "USD",
      account_id: "ethereum",
      raw_payload: { address: "0x123abc", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    # DeFi response: 32 ETH staked, total position value = $70,272 (= 32 * $2196)
    # The `price` field is TotalValueDto (total position value), NOT price per token.
    defi_response = {
      protocols: [
        {
          id: "lido",
          name: "Lido",
          logo: "https://example.com/lido.png",
          investments: [
            {
              name: "Staking",
              assets: [
                {
                  title: "Deposit",
                  coinId: "ethereum",
                  symbol: "ETH",
                  amount: 32.0,
                  price: { USD: 70272.0 }  # total value, not per-token
                }
              ]
            }
          ]
        }
      ]
    }

    @mock_provider.expects(:get_wallet_defi)
      .with(address: "0x123abc", connection_id: "ethereum")
      .returns(success_response(defi_response))

    @mock_provider.stubs(:get_wallet_balances).returns(success_response([]))
    @mock_provider.stubs(:extract_wallet_balance).returns([])
    @mock_provider.stubs(:get_wallet_transactions).returns(success_response([]))
    @mock_provider.stubs(:extract_wallet_transactions).returns([])

    assert_difference "CoinstatsAccount.count", 1 do
      assert_difference "Account.count", 1 do
        CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider).import
      end
    end

    defi_account = @coinstats_item.coinstats_accounts.find_by(account_id: "defi:ethereum:lido:staking:ethereum:deposit")
    assert_not_nil defi_account
    assert_equal "defi", defi_account.raw_payload["source"]
    # Balance must be the total position value ($70,272), NOT 32 * $70,272
    assert_equal 70272.0, defi_account.current_balance.to_f
    assert_equal "ETH (Lido Staking)", defi_account.name
  end

  test "zeros out DeFi account when staking position is no longer active" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Ethereum Wallet",
      balance: 1000,
      currency: "USD"
    )
    wallet_account = @coinstats_item.coinstats_accounts.create!(
      name: "Ethereum (0x12...abc)",
      currency: "USD",
      account_id: "ethereum",
      raw_payload: { address: "0x123abc", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account, provider: wallet_account)

    # Existing DeFi account from a previous sync
    defi_crypto = Crypto.create!
    defi_linked_account = @family.accounts.create!(
      accountable: defi_crypto,
      name: "ETH (Lido Staking)",
      balance: 70272,
      currency: "USD"
    )
    defi_account = @coinstats_item.coinstats_accounts.create!(
      name: "ETH (Lido Staking)",
      currency: "USD",
      account_id: "defi:ethereum:lido:staking:ethereum:deposit",
      wallet_address: "0x123abc",
      current_balance: 70272,
      raw_payload: {
        source: "defi",
        address: "0x123abc",
        blockchain: "ethereum",
        protocol_id: "lido",
        amount: 32.0,
        balance: 70272.0
      }
    )
    AccountProvider.create!(account: defi_linked_account, provider: defi_account)

    # DeFi response returns empty — position has been fully unstaked
    @mock_provider.expects(:get_wallet_defi)
      .with(address: "0x123abc", connection_id: "ethereum")
      .returns(success_response({ protocols: [] }))

    @mock_provider.stubs(:get_wallet_balances).returns(success_response([]))
    @mock_provider.stubs(:extract_wallet_balance).returns([])
    @mock_provider.stubs(:get_wallet_transactions).returns(success_response([]))
    @mock_provider.stubs(:extract_wallet_transactions).returns([])

    CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider).import

    defi_account.reload
    assert_equal 0.0, defi_account.current_balance.to_f
  end

  test "defi accounts are skipped in wallet update loop" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Ethereum Wallet",
      balance: 1000,
      currency: "USD"
    )
    wallet_account = @coinstats_item.coinstats_accounts.create!(
      name: "Ethereum",
      currency: "USD",
      account_id: "ethereum",
      raw_payload: { address: "0x123abc", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account, provider: wallet_account)

    defi_crypto = Crypto.create!
    defi_linked_account = @family.accounts.create!(
      accountable: defi_crypto,
      name: "ETH (Lido Staking)",
      balance: 1000,
      currency: "USD"
    )
    defi_account = @coinstats_item.coinstats_accounts.create!(
      name: "ETH (Lido Staking)",
      currency: "USD",
      account_id: "defi:ethereum:lido:staking:ethereum:deposit",
      wallet_address: "0x123abc",
      current_balance: 1000,
      raw_payload: {
        source: "defi",
        address: "0x123abc",
        blockchain: "ethereum",
        amount: 0.5,
        balance: 1000.0
      }
    )
    AccountProvider.create!(account: defi_linked_account, provider: defi_account)

    # get_wallet_defi called once (for the one wallet), get_wallet_balances/transactions only
    # called once despite two linked accounts (DeFi account excluded from wallet fetch)
    @mock_provider.expects(:get_wallet_defi)
      .with(address: "0x123abc", connection_id: "ethereum")
      .once
      .returns(success_response({ protocols: [] }))

    @mock_provider.expects(:get_wallet_balances).with("ethereum:0x123abc").once
      .returns(success_response([]))
    @mock_provider.stubs(:extract_wallet_balance).returns([])
    @mock_provider.expects(:get_wallet_transactions).with("ethereum:0x123abc").once
      .returns(success_response([]))
    @mock_provider.stubs(:extract_wallet_transactions).returns([])

    result = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider).import

    assert result[:success]
  end

  test "propagates DeFi sync failure into accounts_failed count" do
    crypto = Crypto.create!
    account = @family.accounts.create!(
      accountable: crypto,
      name: "Ethereum Wallet",
      balance: 1000,
      currency: "USD"
    )
    coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Ethereum",
      currency: "USD",
      account_id: "ethereum",
      raw_payload: { address: "0x123abc", blockchain: "ethereum" }
    )
    AccountProvider.create!(account: account, provider: coinstats_account)

    @mock_provider.expects(:get_wallet_defi)
      .with(address: "0x123abc", connection_id: "ethereum")
      .raises(Provider::Coinstats::Error.new("DeFi endpoint unavailable"))

    @mock_provider.stubs(:get_wallet_balances).returns(success_response([]))
    @mock_provider.stubs(:extract_wallet_balance).returns([])
    @mock_provider.stubs(:get_wallet_transactions).returns(success_response([]))
    @mock_provider.stubs(:extract_wallet_transactions).returns([])

    result = CoinstatsItem::Importer.new(@coinstats_item, coinstats_provider: @mock_provider).import

    # Wallet account still updated, but DeFi failure is counted
    assert_equal 1, result[:accounts_failed]
    refute result[:success]
  end
end
