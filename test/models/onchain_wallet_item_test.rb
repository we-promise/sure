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
end
