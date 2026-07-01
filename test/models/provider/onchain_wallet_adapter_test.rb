require "test_helper"
require "uri"

class Provider::OnchainWalletAdapterTest < ActiveSupport::TestCase
  test "supports Crypto accounts only" do
    assert_includes Provider::OnchainWalletAdapter.supported_account_types, "Crypto"
    assert_not_includes Provider::OnchainWalletAdapter.supported_account_types, "Depository"
  end

  test "connection config links new Crypto accounts to wallet modal" do
    configs = Provider::OnchainWalletAdapter.connection_configs(family: families(:dylan_family))

    assert_equal 1, configs.length
    assert_equal "onchain_wallet", configs.first[:key]
    assert_equal "On-chain Wallets", configs.first[:name]

    new_account_uri = URI.parse(configs.first[:new_account_path].call("Crypto", "/accounts"))
    assert_equal "/onchain_wallet_items/new_wallet", new_account_uri.path
  end
end
