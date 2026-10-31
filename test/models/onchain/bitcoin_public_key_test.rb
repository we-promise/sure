require "test_helper"

class Onchain::BitcoinPublicKeyTest < ActiveSupport::TestCase
  # Public BIP84 test vectors (BIP84 spec), never a user's keys.
  ZPUB = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs"
  RECEIVE = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"
  SECOND = "bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g"
  CHANGE = "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el"

  # The same BIP84 test account key with xpub version bytes instead of zpub.
  XPUB = "xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V"

  test "derives official BIP84 receive and change addresses" do
    key = Onchain::BitcoinPublicKey.new(ZPUB)
    assert_equal RECEIVE, key.address(0, 0)
    assert_equal SECOND, key.address(0, 1)
    assert_equal CHANGE, key.address(1, 0)
  end

  test "derives only receive and change branches at non-hardened indices" do
    # An account public key cannot derive hardened children; 0x80000000 would be one.
    key = Onchain::BitcoinPublicKey.new(ZPUB)
    [ [ 2, 0 ], [ 0, -1 ], [ 0, 0x80000000 ] ].each do |branch, index|
      assert_raises(Onchain::BitcoinPublicKey::InvalidKey) { key.address(branch, index) }
    end
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

  test "accepts only hardened account-level keys" do
    # BIP32 test vectors: m/0H is the depth-1 node Electrum segwit seeds export;
    # the master key (depth 0) and non-hardened m/0 are not accounts.
    assert Onchain::BitcoinPublicKey.new("xpub68Gmy5EdvgibQVfPdqkBBCHxA5htiqg55crXYuXoQRKfDBFA1WEjWgP6LHhwBZeNK1VTsfTFUHCdrfp1bgwQ9xv5ski8PX9rL2dZXvgGDnw").address(0, 0).start_with?("bc1q")
    %w[
      xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8
      xpub69H7F5d8KSRgmmdJg2KhpAK8SR3DjMwAdkxj3ZuxV27CprR9LgpeyGmXUbC6wb7ERfvrnKZjXoUmmDznezpbZb7ap6r1D3tgFxHmwMkQTPH
    ].each do |value|
      error = assert_raises(Onchain::BitcoinPublicKey::InvalidKey) { Onchain::BitcoinPublicKey.new(value) }
      assert_equal "Use an account-level extended public key", error.message
    end
  end

  test "validates Bitcoin addresses using their checksum" do
    assert Onchain::BitcoinPublicKey.valid_address?(RECEIVE)
    refute Onchain::BitcoinPublicKey.valid_address?(RECEIVE.chop + "a")
    refute Onchain::BitcoinPublicKey.valid_address?("tb1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
  end

  test "canonicalizes only uniformly cased Bech32 addresses" do
    assert_equal RECEIVE, Onchain::BitcoinPublicKey.canonical_address("  #{RECEIVE.upcase} ")
    # BIP173: mixed case is invalid, so it is kept for validation to reject, not repaired.
    mixed = RECEIVE.sub("bc1q", "bc1Q")
    assert_equal mixed, Onchain::BitcoinPublicKey.canonical_address(mixed)
    refute Onchain::BitcoinPublicKey.valid_address?(mixed)
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
