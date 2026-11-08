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

  test "a replaced key is parsed again" do
    source = build_bitcoin_wallet.bitcoin_wallet_sources.new(kind: "bip84", receive_address: RECEIVE, extended_public_key: ZPUB)
    assert source.valid?
    source.extended_public_key = "zpub-not-a-key"
    refute source.valid?
    assert_includes source.errors.details[:extended_public_key], { error: :invalid }
  end

  test "removing a source releases the addresses it claimed" do
    wallet = build_bitcoin_wallet
    manual = manual_bitcoin_source(wallet, "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")
    key = wallet.bitcoin_wallet_sources.create!(kind: "bip84", extended_public_key: ZPUB, receive_address: RECEIVE)
    assert BitcoinWalletAccount::Discovery.new(wallet, provider: FakeProvider.new).perform

    key.destroy!
    assert_equal [ manual.receive_address ], wallet.bitcoin_wallet_addresses.reload.pluck(:address)
    manual.destroy!
    assert_empty wallet.bitcoin_wallet_addresses.reload
  end

  test "private material is not accepted in either source mode" do
    wallet = build_bitcoin_wallet
    %w[address bip84].each do |kind|
      source = wallet.bitcoin_wallet_sources.new(kind: kind, receive_address: RECEIVE, extended_public_key: "xprv-secret")
      refute source.valid?
    end
  end
end
