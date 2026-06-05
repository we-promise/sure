# frozen_string_literal: true

require "test_helper"

class OnchainWalletItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = OnchainWalletItem.create!(family: @family, name: "On-chain Wallets")
  end

  test "import_wallet! with bitcoin creates wallet account and sure account" do
    address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
    address_payload = {
      "chain_stats" => { "funded_txo_sum" => 200_000_000, "spent_txo_sum" => 50_000_000 },
      "mempool_stats" => { "funded_txo_sum" => 0, "spent_txo_sum" => 0 }
    }
    confirmed_txs = [
      { "txid" => "abc123", "vout" => [{ "scriptpubkey_address" => address, "value" => 200_000_000 }], "vin" => [] }
    ]

    provider = Provider::MempoolSpace.new
    provider.expects(:get_address).with(address).returns(address_payload)
    provider.expects(:get_address_txs).with(address).returns(confirmed_txs)
    provider.expects(:get_mempool_txs).with(address).returns([])
    @item.expects(:mempool_space_provider).returns(provider)

    OnchainWalletAccount::SecurityResolver.expects(:resolve).returns(nil)

    importer = OnchainWalletItem::Importer.new(@item)
    importer.import_wallet!(chain: "bitcoin", address: address)

    wallet_account = @item.onchain_wallet_accounts.find_by(chain: "bitcoin", wallet_address: address)
    assert wallet_account.present?
    assert_equal "BTC", wallet_account.symbol
    assert_equal "native", wallet_account.asset_kind
    assert_equal 1.5, wallet_account.quantity.to_f
  end

  test "import_wallet! raises for unsupported chain" do
    importer = OnchainWalletItem::Importer.new(@item)

    assert_raises(ArgumentError) do
      importer.import_wallet!(chain: "solana", address: "abc")
    end
  end

  test "import_wallet! with bitcoin raises when no balance or transactions found" do
    address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
    address_payload = {
      "chain_stats" => { "funded_txo_sum" => 0, "spent_txo_sum" => 0 },
      "mempool_stats" => { "funded_txo_sum" => 0, "spent_txo_sum" => 0 }
    }

    provider = Provider::MempoolSpace.new
    provider.expects(:get_address).with(address).returns(address_payload)
    provider.expects(:get_address_txs).with(address).returns([])
    provider.expects(:get_mempool_txs).with(address).returns([])
    @item.expects(:mempool_space_provider).returns(provider)

    importer = OnchainWalletItem::Importer.new(@item)

    assert_raises(Provider::MempoolSpace::InvalidAddressError) do
      importer.import_wallet!(chain: "bitcoin", address: address)
    end
  end

  test "import_ethereum_wallet! creates native ETH account" do
    address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"

    provider = Provider::Etherscan.new(api_key: "test_key")
    provider.expects(:get_native_balance).with(address).returns("2000000000000000000")
    provider.expects(:get_normal_transactions).with(address).returns([{ "hash" => "0xabc", "from" => address, "to" => "0x123", "value" => "1000000000000000000" }])
    provider.expects(:get_erc20_transfers).with(address).returns([])
    @item.expects(:etherscan_provider).returns(provider)

    OnchainWalletAccount::SecurityResolver.expects(:resolve).returns(nil)

    importer = OnchainWalletItem::Importer.new(@item)
    importer.import_ethereum_wallet!(address: address, selected_token_contracts: [])

    wallet_account = @item.onchain_wallet_accounts.find_by(chain: "ethereum", wallet_address: address, asset_kind: "native")
    assert wallet_account.present?
    assert_equal "ETH", wallet_account.symbol
    assert_equal 2.0, wallet_account.quantity.to_f
  end

  test "import_ethereum_wallet! raises without etherscan provider" do
    @item.expects(:etherscan_provider).returns(nil)

    importer = OnchainWalletItem::Importer.new(@item)

    assert_raises(Provider::Etherscan::AuthenticationError) do
      importer.import_ethereum_wallet!(address: "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae", selected_token_contracts: [])
    end
  end

  test "import creates wallet accounts for all linked wallets" do
    address = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"
    @item.onchain_wallet_accounts.create!(
      chain: "bitcoin",
      wallet_address: address,
      asset_kind: "native",
      symbol: "BTC",
      name: "Bitcoin",
      currency: "USD",
      quantity: 1,
      current_balance: 50_000
    )

    address_payload = {
      "chain_stats" => { "funded_txo_sum" => 100_000_000, "spent_txo_sum" => 0 },
      "mempool_stats" => { "funded_txo_sum" => 0, "spent_txo_sum" => 0 }
    }

    provider = Provider::MempoolSpace.new
    provider.expects(:get_address).with(address).returns(address_payload)
    provider.expects(:get_address_txs).with(address).returns([{ "txid" => "tx1", "vout" => [{ "scriptpubkey_address" => address, "value" => 100_000_000 }], "vin" => [] }])
    provider.expects(:get_mempool_txs).with(address).returns([])
    @item.expects(:mempool_space_provider).returns(provider)

    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)

    importer = OnchainWalletItem::Importer.new(@item)
    result = importer.import

    assert result[:success]
    assert_equal 1, result[:wallets_imported]
  end
end
