# frozen_string_literal: true

require "test_helper"

class OnchainWalletItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "belongs to family and has good status by default" do
    item = OnchainWalletItem.create!(family: @family, name: "On-chain Wallets")

    assert_equal @family, item.family
    assert_equal "good", item.status
  end

  test "strips etherscan api key whitespace" do
    item = OnchainWalletItem.create!(family: @family, name: "Wallets", etherscan_api_key: " key \n")

    assert_equal "key", item.etherscan_api_key
  end

  test "defaults ethereum data provider to blockscout" do
    item = OnchainWalletItem.create!(family: @family, name: "Wallets")

    assert_equal "blockscout", item.ethereum_data_provider
  end

  test "credentials_configured only requires an etherscan key when etherscan is selected" do
    item = OnchainWalletItem.new(family: @family, name: "Wallets")
    assert item.credentials_configured?

    item.ethereum_data_provider = "etherscan"
    refute item.credentials_configured?
    item.etherscan_api_key = "key"
    assert item.credentials_configured?
  end

  test "etherscan provider requires an api key" do
    item = OnchainWalletItem.new(family: @family, name: "Wallets", ethereum_data_provider: "etherscan")

    assert_not item.valid?
    assert_includes item.errors[:etherscan_api_key], "can't be blank"
  end

  test "evm_provider uses etherscan only for ethereum when selected" do
    item = OnchainWalletItem.create!(
      family: @family,
      name: "Wallets",
      ethereum_data_provider: "etherscan",
      etherscan_api_key: "key"
    )

    assert_instance_of Provider::Etherscan, item.evm_provider("ethereum")
    assert_instance_of Provider::Blockscout, item.evm_provider("polygon")
  end

  test "importer estimates current balance from resolved crypto price" do
    item = OnchainWalletItem.create!(family: @family, name: "On-chain Wallets")
    security = Security.create!(
      ticker: "BTCUSD",
      exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC,
      price_provider: "binance_public"
    )
    security.prices.create!(date: Date.current, price: 50_000, currency: "USD")
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).with("BTC", "BTC").returns(security)

    balance = OnchainWalletItem::Importer.new(item).send(:estimate_current_balance, "BTC", 2)

    assert_equal 100_000.to_d, balance
  end

  test "importer keeps quantity value path resilient when price lookup fails" do
    item = OnchainWalletItem.create!(family: @family, name: "On-chain Wallets")
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).raises(StandardError.new("provider down"))

    balance = OnchainWalletItem::Importer.new(item).send(:estimate_current_balance, "BTC", 2)

    assert_equal 0, balance
  end

  test "ethereum wallet import persists only selected token contracts" do
    item = OnchainWalletItem.create!(family: @family, name: "On-chain Wallets", etherscan_api_key: "key")
    address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"
    selected_contract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    skipped_contract = "0x1111111111111111111111111111111111111111"

    Provider::Blockscout.any_instance.stubs(:get_native_balance).returns("1000000000000000000")
    Provider::Blockscout.any_instance.stubs(:get_normal_transactions).returns([])
    Provider::Blockscout.any_instance.stubs(:get_erc20_transfers).returns([
      erc20_transfer(address: address, contract: selected_contract, symbol: "USDC", name: "USD Coin", decimals: "6", value: "5000000"),
      erc20_transfer(address: address, contract: skipped_contract, symbol: "SCAM", name: "Visit scam.example", decimals: "18", value: "1000000000000000000000")
    ])
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)

    OnchainWalletItem::Importer.new(item).import_ethereum_wallet!(
      address: address,
      selected_token_contracts: [ selected_contract ]
    )

    assert item.onchain_wallet_accounts.exists?(chain: "ethereum", wallet_address: address, asset_kind: "native", symbol: "ETH")
    assert item.onchain_wallet_accounts.exists?(chain: "ethereum", wallet_address: address, asset_kind: "erc20", token_contract: selected_contract)
    assert_not item.onchain_wallet_accounts.exists?(chain: "ethereum", wallet_address: address, asset_kind: "erc20", token_contract: skipped_contract)
  end

  test "ethereum sync updates tracked token to zero when balance is fully spent" do
    item = OnchainWalletItem.create!(family: @family, name: "On-chain Wallets", etherscan_api_key: "key")
    address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"
    tracked_contract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

    # Pre-existing tracked token with a non-zero balance
    item.onchain_wallet_accounts.create!(
      chain: "ethereum",
      wallet_address: address,
      asset_kind: "erc20",
      token_contract: tracked_contract,
      symbol: "USDC",
      name: "USD Coin",
      currency: "USD",
      quantity: 5.0,
      current_balance: 5.0
    )

    # Simulate transfers that net to zero (received then sent same amount)
    Provider::Blockscout.any_instance.stubs(:get_native_balance).returns("1000000000000000000")
    Provider::Blockscout.any_instance.stubs(:get_normal_transactions).returns([])
    Provider::Blockscout.any_instance.stubs(:get_erc20_transfers).returns([
      erc20_transfer(address: address, contract: tracked_contract, symbol: "USDC", name: "USD Coin", decimals: "6", value: "5000000"),
      {
        "contractAddress" => tracked_contract,
        "tokenSymbol" => "USDC",
        "tokenName" => "USD Coin",
        "tokenDecimal" => "6",
        "value" => "5000000",
        "from" => address,
        "to" => "0x1111111111111111111111111111111111111111",
        "hash" => "#{tracked_contract}-out-hash"
      }
    ])
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)

    OnchainWalletItem::Importer.new(item).import_wallet!(chain: "ethereum", address: address)

    account = item.onchain_wallet_accounts.find_by(token_contract: tracked_contract)
    assert account, "Tracked token account should still exist"
    assert_equal 0.to_d, account.quantity
    assert_equal 0.to_d, account.current_balance
  end

  test "ethereum provider sync does not import newly discovered token contracts" do
    item = OnchainWalletItem.create!(family: @family, name: "On-chain Wallets", etherscan_api_key: "key")
    address = "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae"
    existing_contract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    new_contract = "0x1111111111111111111111111111111111111111"
    item.onchain_wallet_accounts.create!(
      chain: "ethereum",
      wallet_address: address,
      asset_kind: "erc20",
      token_contract: existing_contract,
      symbol: "USDC",
      name: "USD Coin",
      currency: "USD"
    )

    Provider::Blockscout.any_instance.stubs(:get_native_balance).returns("0")
    Provider::Blockscout.any_instance.stubs(:get_normal_transactions).returns([])
    Provider::Blockscout.any_instance.stubs(:get_erc20_transfers).returns([
      erc20_transfer(address: address, contract: existing_contract, symbol: "USDC", name: "USD Coin", decimals: "6", value: "5000000"),
      erc20_transfer(address: address, contract: new_contract, symbol: "SCAM", name: "Visit scam.example", decimals: "18", value: "1000000000000000000000")
    ])
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)

    OnchainWalletItem::Importer.new(item).import_wallet!(chain: "ethereum", address: address)

    assert item.onchain_wallet_accounts.exists?(token_contract: existing_contract)
    assert_not item.onchain_wallet_accounts.exists?(token_contract: new_contract)
  end

  private
    def erc20_transfer(address:, contract:, symbol:, name:, decimals:, value:)
      {
        "contractAddress" => contract,
        "tokenSymbol" => symbol,
        "tokenName" => name,
        "tokenDecimal" => decimals,
        "value" => value,
        "from" => "0x0000000000000000000000000000000000000000",
        "to" => address,
        "hash" => "#{contract}-hash"
      }
    end
end
