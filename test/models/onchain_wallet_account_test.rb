# frozen_string_literal: true

require "test_helper"

class OnchainWalletAccountTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = OnchainWalletItem.create!(family: @family, name: "On-chain Wallets")
  end

  test "normalizes ethereum addresses and symbols" do
    account = @item.onchain_wallet_accounts.create!(
      chain: "Ethereum",
      wallet_address: "0xDe0B295669a9FD93d5F28D9Ec85E40f4cb697BAe",
      asset_kind: "native",
      symbol: "eth",
      name: "Ethereum"
    )

    assert_equal "ethereum", account.chain
    assert_equal "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae", account.wallet_address
    assert_equal "ETH", account.symbol
  end

  test "requires token contract for erc20 assets" do
    account = @item.onchain_wallet_accounts.build(
      chain: "ethereum",
      wallet_address: "0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae",
      asset_kind: "erc20",
      symbol: "USDC",
      name: "USD Coin"
    )

    assert_not account.valid?
    assert_includes account.errors[:token_contract], "can't be blank"
  end

  test "links through account provider" do
    wallet_account = @item.onchain_wallet_accounts.create!(
      chain: "bitcoin",
      wallet_address: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080",
      asset_kind: "native",
      symbol: "BTC",
      name: "Bitcoin"
    )
    account = Account.create!(
      family: @family,
      name: "BTC Wallet",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "wallet")
    )

    wallet_account.ensure_account_provider!(account)

    assert_equal account, wallet_account.reload.current_account
  end

  test "processor updates linked account balance from current balance" do
    wallet_account = @item.onchain_wallet_accounts.create!(
      chain: "bitcoin",
      wallet_address: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080",
      asset_kind: "native",
      symbol: "BTC",
      name: "Bitcoin",
      currency: "USD",
      quantity: 1,
      current_balance: 50_000
    )
    account = Account.create_from_onchain_wallet_account(wallet_account)
    wallet_account.ensure_account_provider!(account)
    wallet_account.update!(current_balance: 60_000)
    OnchainWalletAccount::SecurityResolver.stubs(:resolve).returns(nil)

    OnchainWalletAccount::Processor.new(wallet_account).process

    assert_equal 60_000.to_d, account.reload.balance
  end

  test "detect_chain_type recognizes address formats" do
    assert_equal :bitcoin, OnchainWalletAccount.detect_chain_type("bc1qsg9af88zfjz4cy5255pvvg0hj7gamquua7kmgx")
    assert_equal :evm, OnchainWalletAccount.detect_chain_type("0xf5c6b8e6eb92e560a33f6fd6d86a1c734d2d7840")
    assert_equal :solana, OnchainWalletAccount.detect_chain_type("EnQtaNYKgnbSaZ1ekZYXVbYnau2ZCNda3NzbbnWCna7B")
    assert_nil OnchainWalletAccount.detect_chain_type("not-a-wallet!!")
  end
end
