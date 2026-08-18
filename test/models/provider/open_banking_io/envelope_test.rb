require "test_helper"

# The zero-knowledge envelope is the only thing standing between the service and the
# user's financial history, and it had no test coverage at all: the client test stubs
# Provider::OpenBankingIo::Client wholesale, so nothing ever exercised a real decryption.
#
# The KAT fixture is vendored verbatim from the service repo
# (open-banking-io/tests/fixtures/envelope-kat.json, regenerate with
# `node tools/generate-envelope-kat.mjs`). The same file is consumed by EnvelopeKatTests.cs
# and crypto.kat.test.ts, so decrypting it here proves this Ruby reader is byte-identical
# to the C# and TypeScript ones. It carries its own throwaway P-256 keypair -- no real key
# material is committed.
class Provider::OpenBankingIo::EnvelopeTest < ActiveSupport::TestCase
  Envelope = Provider::OpenBankingIo::Envelope

  setup do
    @kat = JSON.parse(file_fixture("open_banking_io/envelope-kat.json").read)
    @key = Envelope.load_private_key(@kat.dig("keypair", "privateKeyPkcs8B64"))
    @v1 = @kat["vectors"].find { |v| v["version"] == 1 }
  end

  def envelope_bytes(vector = @v1)
    Base64.strict_decode64(vector["envelopeB64"])
  end

  def rebuild(bytes)
    Base64.strict_encode64(bytes)
  end

  # === CROSS-LANGUAGE KNOWN-ANSWER TEST ===

  test "decrypts the v1 cross-language vector to its pinned plaintext" do
    assert @v1, "the fixture must carry a v1 vector"
    assert_equal @v1["expected"], Envelope.decrypt_to_json(@key, @v1["envelopeB64"])
  end

  test "the fixture pins the hkdf parameters this reader implements" do
    assert_equal "bank.core.ci/zk/v1", @kat.dig("hkdf", "v1Info")
    assert_equal Envelope::HKDF_INFO, @kat.dig("hkdf", "v1Info").b
    assert_equal ("\x00".b * 32), Envelope::HKDF_SALT
  end

  # The service writer can emit v2 (context-bound) envelopes but is pinned to v1 until
  # every SDK reader understands them. If that pin is ever lifted this reader must fail
  # loudly on the new version byte rather than mis-deriving a key -- and this test is the
  # tripwire that says so, listing exactly which vectors are not yet supported.
  test "v2 vectors are rejected with an explicit unsupported-version error" do
    v2_vectors = @kat["vectors"].select { |v| v["version"] == 2 }
    assert_not_empty v2_vectors

    v2_vectors.each do |vector|
      error = assert_raises(ArgumentError) { Envelope.decrypt_to_json(@key, vector["envelopeB64"]) }
      assert_match(/Unsupported envelope version 2/, error.message, vector["name"])
    end
  end

  # === KEY LOADING ===

  test "rejects a non-EC private key" do
    rsa = OpenSSL::PKey::RSA.generate(2048)
    error = assert_raises(ArgumentError) { Envelope.load_private_key(Base64.strict_encode64(rsa.to_der)) }
    assert_equal "Private key is not an EC key", error.message
  end

  # A malformed key raises OpenSSL::PKey::PKeyError, which is not an ArgumentError -- so it
  # used to escape the :configuration_error mapping and surface to the user as a generic
  # sync failure that never flipped the item to requires_update.
  test "wraps an unparseable private key in ArgumentError" do
    assert_raises(ArgumentError) { Envelope.load_private_key(Base64.strict_encode64("not a key")) }
  end

  test "rejects a private key that is not strict base64" do
    error = assert_raises(ArgumentError) { Envelope.load_private_key("MIGHAgEAMB!!! not base64") }
    assert_match(/Invalid base64/, error.message)
  end

  # === WIRE FORMAT ===

  test "rejects an unknown version byte" do
    bytes = envelope_bytes.dup
    bytes.setbyte(0, 0x09)
    error = assert_raises(ArgumentError) { Envelope.decrypt_to_json(@key, rebuild(bytes)) }
    assert_match(/Unsupported envelope version 9/, error.message)
  end

  test "rejects a truncated envelope" do
    truncated = envelope_bytes.byteslice(0, 93)
    error = assert_raises(ArgumentError) { Envelope.decrypt_to_json(@key, rebuild(truncated)) }
    assert_equal "Envelope too short", error.message
  end

  test "rejects an envelope that is not strict base64" do
    error = assert_raises(ArgumentError) { Envelope.decrypt_to_json(@key, "AQ!!ID$%^&*") }
    assert_match(/Invalid base64/, error.message)
  end

  test "treats a nil or empty envelope as absent rather than corrupt" do
    assert_nil Envelope.decrypt_to_json(@key, nil)
    assert_nil Envelope.decrypt_to_json(@key, "")
  end

  # === EPHEMERAL POINT ===

  test "rejects an off-curve ephemeral public key" do
    bytes = envelope_bytes.dup
    bytes.setbyte(64, bytes.getbyte(64) ^ 0xFF) # corrupt Y
    error = assert_raises(ArgumentError) { Envelope.decrypt_to_json(@key, rebuild(bytes)) }
    assert_match(/Invalid ephemeral public key/, error.message)
  end

  # 65 zero bytes decode to the point at infinity, which OpenSSL accepts silently. Only
  # dh_compute_key objected, and it raises PKeyError -- outside this module's contract.
  test "rejects the point at infinity" do
    bytes = envelope_bytes.dup
    bytes[1, Provider::OpenBankingIo::Envelope::POINT_LEN] = "\x00".b * Provider::OpenBankingIo::Envelope::POINT_LEN
    error = assert_raises(ArgumentError) { Envelope.decrypt_to_json(@key, rebuild(bytes)) }
    assert_match(/Invalid ephemeral public key/, error.message)
  end

  # Hybrid encodings decode to the same point and OpenSSL accepts them, but
  # EnvelopeCrypto.ImportPublicPoint and WebCrypto's importKey both reject anything but
  # 0x04. Accepting them would make this reader disagree with the other two on the same
  # bytes -- exactly what the cross-reader invariant forbids.
  test "rejects hybrid point encodings that the C# and browser readers refuse" do
    [ 0x06, 0x07 ].each do |prefix|
      bytes = envelope_bytes.dup
      bytes.setbyte(1, prefix)
      error = assert_raises(ArgumentError) { Envelope.decrypt_to_json(@key, rebuild(bytes)) }
      assert_match(/uncompressed point/, error.message, "prefix #{prefix}")
    end
  end

  # === AUTHENTICITY ===

  test "rejects a tampered auth tag" do
    bytes = envelope_bytes.dup
    tag_offset = 1 + Envelope::POINT_LEN + Envelope::NONCE_LEN
    bytes.setbyte(tag_offset, bytes.getbyte(tag_offset) ^ 0x01)
    assert_raises(OpenSSL::Cipher::CipherError) { Envelope.decrypt_to_json(@key, rebuild(bytes)) }
  end

  test "rejects tampered ciphertext" do
    bytes = envelope_bytes.dup
    ct_offset = 1 + Envelope::POINT_LEN + Envelope::NONCE_LEN + Envelope::TAG_LEN
    bytes.setbyte(ct_offset, bytes.getbyte(ct_offset) ^ 0x01)
    assert_raises(OpenSSL::Cipher::CipherError) { Envelope.decrypt_to_json(@key, rebuild(bytes)) }
  end

  test "rejects an envelope sealed for a different recipient" do
    other = OpenSSL::PKey::EC.generate("prime256v1")
    assert_raises(OpenSSL::Cipher::CipherError) { Envelope.decrypt_to_json(other, @v1["envelopeB64"]) }
  end
end
