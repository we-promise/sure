require "test_helper"
require "support/bitcoin_wallet_test_helper"

class Onchain::BitcoinPublicKeyTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  # The BIP84 test account key with xpub version bytes instead of zpub.
  XPUB = "xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V"

  test "derives official BIP84 receive and change addresses" do
    key = Onchain::BitcoinPublicKey.new(ZPUB)
    assert_equal RECEIVE, key.address(0, 0)
    assert_equal SECOND, key.address(0, 1)
    assert_equal CHANGE, key.address(1, 0)
  end

  test "derives the official BIP32 public child" do
    # Test vector 1: m/0H/1/2H and its non-hardened child m/0H/1/2H/2.
    key = Onchain::BitcoinPublicKey.new("xpub6D4BDPcP2GT577Vvch3R8wDkScZWzQzMMUm3PWbmWvVJrZwQY4VUNgqFJPMM3No2dFDFGTsxxpG5uJh7n7epu4trkrX7x7DogT5Uv6fcLW5")
    pub, chain_code = key.send(:derive, key.instance_variable_get(:@pub), key.instance_variable_get(:@chain_code), 2)
    assert_equal "02e8445082a72f29b75ca48748a914df60622a609cacfce8ed0e35804560741d29", pub.unpack1("H*")
    assert_equal "cfb71883f01676f587d023cc53a35bc7f88f724b1f8c2892ac1275ac822a3edd", chain_code.unpack1("H*")
  end

  test "xpub and zpub versions identify the same source" do
    plain = Onchain::BitcoinPublicKey.new(XPUB)
    assert_equal RECEIVE, plain.address(0, 0)
    assert_equal Onchain::BitcoinPublicKey.new(ZPUB).fingerprint, plain.fingerprint
  end

  test "fingerprints stay compatible with stored sources" do
    assert_equal "e9c5945c1ed8fb33780fc09caf0a79b8852eed6df035db9e04c340dacce83d97", Onchain::BitcoinPublicKey.new(ZPUB).fingerprint
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

  test "accepts every standard mainnet output type and nothing else" do
    %w[
      1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2
      3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy
      bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3
      bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr
    ].each { |address| assert Onchain::BitcoinPublicKey.valid_address?(address), address }

    %w[
      1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN3
      mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn
      bc1qcr8te4kr609gcawutmrza0j4xv80jy8z3hvhsj
    ].each { |address| refute Onchain::BitcoinPublicKey.valid_address?(address), address }
  end
end
