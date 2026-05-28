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

  test "credentials_configured checks etherscan api key" do
    item = OnchainWalletItem.new(family: @family, name: "Wallets")
    refute item.credentials_configured?

    item.etherscan_api_key = "key"
    assert item.credentials_configured?
  end
end
