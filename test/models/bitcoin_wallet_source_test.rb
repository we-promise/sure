require "test_helper"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletSourceTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  test "public keys are encrypted at rest" do
    wallet = build_bitcoin_wallet
    source = wallet.bitcoin_wallet_sources.create!(kind: "bip84", receive_address: RECEIVE, extended_public_key: ZPUB)
    raw = BitcoinWalletSource.connection.select_value("SELECT extended_public_key FROM bitcoin_wallet_sources WHERE id = '#{source.id}'")
    refute_includes raw, ZPUB
    assert_equal ZPUB, source.reload.extended_public_key
  end

  test "unconfigured encryption never falls back to plaintext" do
    ActiveRecordEncryptionConfig.stubs(:ready?).returns(false)
    source = build_bitcoin_wallet.bitcoin_wallet_sources.new(kind: "bip84", receive_address: RECEIVE, extended_public_key: ZPUB)
    refute source.valid?
    assert_includes source.errors[:extended_public_key], "requires configured Active Record encryption"
  end

  test "private material is not accepted in either source mode" do
    wallet = build_bitcoin_wallet
    %w[address bip84].each do |kind|
      source = wallet.bitcoin_wallet_sources.new(kind: kind, receive_address: RECEIVE, extended_public_key: "xprv-secret")
      refute source.valid?
    end
  end
end
