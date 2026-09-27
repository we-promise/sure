require "test_helper"
require "support/bitcoin_wallet_test_helper"

class Onchain::BitcoinPublicKeyTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  test "derives official BIP84 receive and change addresses" do
    key = Onchain::BitcoinPublicKey.new(ZPUB)
    assert_equal RECEIVE, key.address(0, 0)
    assert_equal SECOND, key.address(0, 1)
    assert_equal CHANGE, key.address(1, 0)
  end

  test "xpub and zpub versions identify the same source" do
    key = Bitcoin::ExtPubkey.from_base58(ZPUB)
    key.ver = "0488b21e"
    plain = Onchain::BitcoinPublicKey.new(key.to_base58)
    assert_equal RECEIVE, plain.address(0, 0)
    assert_equal Onchain::BitcoinPublicKey.new(ZPUB).fingerprint, plain.fingerprint
  end

  test "rejects private keys unsupported networks and corrupt checksums" do
    %w[xprv123 zprv123 tpub123 seed].each do |value|
      assert_raises(Onchain::BitcoinPublicKey::InvalidKey) { Onchain::BitcoinPublicKey.new(value) }
    end
    assert_raises(Onchain::BitcoinPublicKey::InvalidKey) { Onchain::BitcoinPublicKey.new(ZPUB.chop + "a") }
  end

  test "validates Bitcoin addresses using their checksum" do
    assert Onchain::BitcoinPublicKey.valid_address?(RECEIVE)
    refute Onchain::BitcoinPublicKey.valid_address?(RECEIVE.chop + "a")
    refute Onchain::BitcoinPublicKey.valid_address?("tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
  end
end
