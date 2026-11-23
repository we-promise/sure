require "test_helper"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletAccountTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  setup do
    @wallet = build_bitcoin_wallet
  end

  test "a wallet can only track a manual account" do
    linked = accounts(:crypto).dup.tap { |account| account.update!(name: "Linked crypto") }
    linked.account_providers.create!(provider: kraken_accounts(:one))
    wallet = BitcoinWalletAccount.new(account: linked, security: @wallet.security, onchain_wallet_item: @wallet.onchain_wallet_item)
    refute wallet.valid?
    assert_includes wallet.errors.details[:account], { error: :linked }
  end

  test "a wallet's account cannot be linked to another provider" do
    link = @wallet.account.account_providers.new(provider: kraken_accounts(:one))
    refute link.valid?
    assert_includes link.errors.details[:account], { error: :bitcoin_wallet }
  end

  test "a wallet cannot track another family's account" do
    other = accounts(:crypto).dup
    other.family = families(:empty)
    other.owner = users(:empty)
    other.save!
    wallet = BitcoinWalletAccount.new(account: other, security: @wallet.security, onchain_wallet_item: @wallet.onchain_wallet_item)
    refute wallet.valid?
    assert_includes wallet.errors.details[:account], { error: :invalid }
  end

  test "a wallet's address is taken for single-address tracking in its family only" do
    @wallet.bitcoin_wallet_addresses.create!(address: RECEIVE)
    assert @wallet.family.onchain_address_linked?(Onchain::Chains::BITCOIN, RECEIVE)
    refute families(:empty).onchain_address_linked?(Onchain::Chains::BITCOIN, RECEIVE)
  end
end
