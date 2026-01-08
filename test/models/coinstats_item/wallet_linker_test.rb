require "test_helper"

class CoinstatsItem::WalletLinkerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @coinstats_item = CoinstatsItem.create!(
      family: @family,
      name: "Test CoinStats Connection",
      api_key: "test_api_key_123"
    )
  end

  # Helper to wrap data in Provider::Response
  def success_response(data)
    Provider::Response.new(success?: true, data: data, error: nil)
  end

  test "link returns failure when no tokens found" do
    Provider::Coinstats.any_instance.expects(:get_wallet_balances)
      .with("ethereum:0x123abc")
      .returns(success_response([]))

    Provider::Coinstats.any_instance.expects(:extract_wallet_balance)
      .with([], "0x123abc", "ethereum")
      .returns([])

    linker = CoinstatsItem::WalletLinker.new(@coinstats_item, address: "0x123abc", blockchain: "ethereum")
    result = linker.link

    refute result.success?
    assert_equal 0, result.created_count
    assert_includes result.errors, "No tokens found for wallet"
  end

  test "link creates account from single token" do
    token_data = [
      {
        coinId: "ethereum",
        name: "Ethereum",
        symbol: "ETH",
        amount: 1.5,
        price: 2000,
        imgUrl: "https://example.com/eth.png"
      }
    ]

    bulk_response = [
      { blockchain: "ethereum", address: "0x123abc", connectionId: "ethereum", balances: token_data }
    ]

    Provider::Coinstats.any_instance.expects(:get_wallet_balances)
      .with("ethereum:0x123abc")
      .returns(success_response(bulk_response))

    Provider::Coinstats.any_instance.expects(:extract_wallet_balance)
      .with(bulk_response, "0x123abc", "ethereum")
      .returns(token_data)

    linker = CoinstatsItem::WalletLinker.new(@coinstats_item, address: "0x123abc", blockchain: "ethereum")

    assert_difference [ "Account.count", "CoinstatsAccount.count", "AccountProvider.count" ], 1 do
      result = linker.link
      assert result.success?
      assert_equal 1, result.created_count
      assert_empty result.errors
    end

    # Verify the account was created correctly
    coinstats_account = @coinstats_item.coinstats_accounts.last
    # Note: upsert_coinstats_snapshot! overwrites name with raw token name
    assert_equal "Ethereum", coinstats_account.name
    assert_equal "USD", coinstats_account.currency
    assert_equal 3000.0, coinstats_account.current_balance.to_f # 1.5 * 2000

    account = coinstats_account.account
    # Account name is set before upsert_coinstats_snapshot so it keeps the formatted name
    assert_equal "Ethereum (0x12...3abc)", account.name
    assert_equal 3000.0, account.balance.to_f
    assert_equal "USD", account.currency
    assert_equal "Crypto", account.accountable_type
  end

  test "link creates multiple accounts from multiple tokens" do
    token_data = [
      { coinId: "ethereum", name: "Ethereum", symbol: "ETH", amount: 2.0, price: 2000 },
      { coinId: "dai", name: "Dai Stablecoin", symbol: "DAI", amount: 1000, price: 1 }
    ]

    bulk_response = [
      { blockchain: "ethereum", address: "0xmulti", connectionId: "ethereum", balances: token_data }
    ]

    Provider::Coinstats.any_instance.expects(:get_wallet_balances)
      .with("ethereum:0xmulti")
      .returns(success_response(bulk_response))

    Provider::Coinstats.any_instance.expects(:extract_wallet_balance)
      .with(bulk_response, "0xmulti", "ethereum")
      .returns(token_data)

    linker = CoinstatsItem::WalletLinker.new(@coinstats_item, address: "0xmulti", blockchain: "ethereum")

    assert_difference "Account.count", 2 do
      assert_difference "CoinstatsAccount.count", 2 do
        result = linker.link
        assert result.success?
        assert_equal 2, result.created_count
      end
    end
  end

  test "link triggers sync after creating accounts" do
    token_data = [
      { coinId: "ethereum", name: "Ethereum", amount: 1.0, price: 2000 }
    ]

    bulk_response = [
      { blockchain: "ethereum", address: "0x123", connectionId: "ethereum", balances: token_data }
    ]

    Provider::Coinstats.any_instance.expects(:get_wallet_balances).returns(success_response(bulk_response))
    Provider::Coinstats.any_instance.expects(:extract_wallet_balance).returns(token_data)
    @coinstats_item.expects(:sync_later).once

    linker = CoinstatsItem::WalletLinker.new(@coinstats_item, address: "0x123", blockchain: "ethereum")
    linker.link
  end

  test "link does not trigger sync when no accounts created" do
    Provider::Coinstats.any_instance.expects(:get_wallet_balances).returns(success_response([]))
    Provider::Coinstats.any_instance.expects(:extract_wallet_balance).returns([])
    @coinstats_item.expects(:sync_later).never

    linker = CoinstatsItem::WalletLinker.new(@coinstats_item, address: "0x123", blockchain: "ethereum")
    linker.link
  end

  test "link stores wallet metadata in raw_payload" do
    token_data = [
      {
        coinId: "ethereum",
        name: "Ethereum",
        symbol: "ETH",
        amount: 1.0,
        price: 2000,
        imgUrl: "https://example.com/eth.png"
      }
    ]

    bulk_response = [
      { blockchain: "ethereum", address: "0xtest123", connectionId: "ethereum", balances: token_data }
    ]

    Provider::Coinstats.any_instance.expects(:get_wallet_balances)
      .with("ethereum:0xtest123")
      .returns(success_response(bulk_response))

    Provider::Coinstats.any_instance.expects(:extract_wallet_balance)
      .with(bulk_response, "0xtest123", "ethereum")
      .returns(token_data)

    linker = CoinstatsItem::WalletLinker.new(@coinstats_item, address: "0xtest123", blockchain: "ethereum")
    linker.link

    coinstats_account = @coinstats_item.coinstats_accounts.last
    raw_payload = coinstats_account.raw_payload

    assert_equal "0xtest123", raw_payload["address"]
    assert_equal "ethereum", raw_payload["blockchain"]
    assert_equal "https://example.com/eth.png", raw_payload["institution_logo"]
  end

  test "link handles account creation errors gracefully" do
    token_data = [
      { coinId: "ethereum", name: "Ethereum", amount: 1.0, price: 2000 },
      { coinId: "bad", name: nil, amount: 1.0, price: 100 } # Will fail validation
    ]

    bulk_response = [
      { blockchain: "ethereum", address: "0xtest", connectionId: "ethereum", balances: token_data }
    ]

    Provider::Coinstats.any_instance.expects(:get_wallet_balances).returns(success_response(bulk_response))
    Provider::Coinstats.any_instance.expects(:extract_wallet_balance).returns(token_data)

    # We need to mock the error scenario - name can't be blank
    linker = CoinstatsItem::WalletLinker.new(@coinstats_item, address: "0xtest", blockchain: "ethereum")

    result = linker.link

    # Should create the valid account but have errors for the invalid one
    assert result.success? # At least one succeeded
    assert result.created_count >= 1
  end

  test "link builds correct account name with address suffix" do
    token_data = [
      { coinId: "ethereum", name: "Ethereum", amount: 1.0, price: 2000 }
    ]

    bulk_response = [
      { blockchain: "ethereum", address: "0xABCDEF123456", connectionId: "ethereum", balances: token_data }
    ]

    Provider::Coinstats.any_instance.expects(:get_wallet_balances).returns(success_response(bulk_response))
    Provider::Coinstats.any_instance.expects(:extract_wallet_balance).returns(token_data)

    linker = CoinstatsItem::WalletLinker.new(@coinstats_item, address: "0xABCDEF123456", blockchain: "ethereum")
    linker.link

    # Account name includes the address suffix (created before upsert_coinstats_snapshot)
    account = @coinstats_item.accounts.last
    assert_equal "Ethereum (0xAB...3456)", account.name
  end

  test "link handles single token as hash instead of array" do
    token_data = {
      coinId: "bitcoin",
      name: "Bitcoin",
      symbol: "BTC",
      amount: 0.5,
      price: 40000
    }

    bulk_response = [
      { blockchain: "bitcoin", address: "bc1qtest", connectionId: "bitcoin", balances: [ token_data ] }
    ]

    Provider::Coinstats.any_instance.expects(:get_wallet_balances).returns(success_response(bulk_response))
    Provider::Coinstats.any_instance.expects(:extract_wallet_balance).returns(token_data)

    linker = CoinstatsItem::WalletLinker.new(@coinstats_item, address: "bc1qtest", blockchain: "bitcoin")

    assert_difference "Account.count", 1 do
      result = linker.link
      assert result.success?
    end

    account = @coinstats_item.coinstats_accounts.last
    assert_equal 20000.0, account.current_balance.to_f # 0.5 * 40000
  end

  test "link stores correct account_id from token" do
    token_data = [
      { coinId: "unique_token_123", name: "My Token", amount: 100, price: 1 }
    ]

    bulk_response = [
      { blockchain: "ethereum", address: "0xtest", connectionId: "ethereum", balances: token_data }
    ]

    Provider::Coinstats.any_instance.expects(:get_wallet_balances).returns(success_response(bulk_response))
    Provider::Coinstats.any_instance.expects(:extract_wallet_balance).returns(token_data)

    linker = CoinstatsItem::WalletLinker.new(@coinstats_item, address: "0xtest", blockchain: "ethereum")
    linker.link

    coinstats_account = @coinstats_item.coinstats_accounts.last
    assert_equal "unique_token_123", coinstats_account.account_id
  end

  test "link falls back to id field for account_id" do
    token_data = [
      { id: "fallback_id_456", name: "Fallback Token", amount: 50, price: 2 }
    ]

    bulk_response = [
      { blockchain: "ethereum", address: "0xtest", connectionId: "ethereum", balances: token_data }
    ]

    Provider::Coinstats.any_instance.expects(:get_wallet_balances).returns(success_response(bulk_response))
    Provider::Coinstats.any_instance.expects(:extract_wallet_balance).returns(token_data)

    linker = CoinstatsItem::WalletLinker.new(@coinstats_item, address: "0xtest", blockchain: "ethereum")
    linker.link

    coinstats_account = @coinstats_item.coinstats_accounts.last
    assert_equal "fallback_id_456", coinstats_account.account_id
  end
end
