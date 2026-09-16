require "test_helper"

class Ingestion::IdentitySigningKeysTest < ActiveSupport::TestCase
  Keys = Ingestion::IdentitySigningKeys

  test "new signatures declare one authenticated key version and verify with its retained key" do
    keys = keyring(active: "first", keys: { "first" => "a" * 32 })
    signature = keys.sign("typed financial proof")

    assert_equal %w[digest key_id version], signature.keys.sort
    assert_equal 1, signature.fetch("version")
    assert_equal "first", signature.fetch("key_id")
    assert signature.frozen?
    assert keys.verify!(signature, "typed financial proof")
    assert_raises(Keys::InvalidSignature) { keys.verify!(signature, "changed financial proof") }
  end

  test "rotation retains old verification without allowing the old key to remain the active signer" do
    original = keyring(active: "first", keys: { "first" => "a" * 32 }).sign("proof")
    rotated = keyring(active: "second", keys: { "first" => "a" * 32, "second" => "b" * 32 })
    replacement = rotated.sign("proof")

    assert rotated.verify!(original, "proof")
    assert rotated.verify!(replacement, "proof")
    assert_equal "second", replacement.fetch("key_id")
    removed = keyring(active: "second", keys: { "second" => "b" * 32 })
    assert_raises(Keys::InvalidSignature) { removed.verify!(original, "proof") }
    assert removed.verify!(replacement, "proof")
    wrong_key = keyring(active: "first", keys: { "first" => "b" * 32 })
    assert_raises(Keys::InvalidSignature) { wrong_key.verify!(original, "proof") }
  end

  test "verification-only configuration cannot sign and absent keys never fall back to application secrets" do
    signer = keyring(active: "first", keys: { "first" => "a" * 32 })
    verifier = keyring(active: nil, keys: { "first" => "a" * 32 })
    Rails.application.expects(:key_generator).never
    Rails.application.expects(:secret_key_base).never

    assert verifier.verify!(signer.sign("proof"), "proof")
    assert_raises(Keys::InvalidConfiguration) { verifier.sign("proof") }
    assert_raises(Keys::InvalidConfiguration) { Keys.new.sign("proof") }
  end

  test "key IDs and signature versions cannot be substituted even when key bytes match" do
    keys = keyring(active: "first", keys: { "first" => "a" * 32, "alias" => "a" * 32 })
    signature = keys.sign("proof")
    changes = [ { "key_id" => "alias" }, { "version" => 2 }, { "digest" => "invalid" }, { "extra" => true } ]

    changes.each do |change|
      assert_raises(Keys::InvalidSignature) { keys.verify!(signature.merge(change), "proof") }
    end
    assert_raises(Keys::InvalidSignature) { keys.verify!(signature.merge(version: 1), "proof") }
    assert_raises(Keys::InvalidSignature) { keys.verify!(nil, "proof") }
  end

  test "unversioned proofs require exactly the explicitly selected historical derived key" do
    historical_key = "h" * 32
    legacy = OpenSSL::HMAC.hexdigest("SHA256", historical_key, "original typed proof")
    stored = { "historical" => historical_key, "current" => "n" * 32 }
    disabled = keyring(active: "current", keys: stored)
    enabled = keyring(active: "current", keys: stored, legacy: "historical")
    wrong_policy = keyring(active: "current", keys: stored, legacy: "current")

    assert_raises(Keys::InvalidSignature) { disabled.verify!(legacy, "original typed proof") }
    assert enabled.verify!(legacy, "original typed proof")
    assert_raises(Keys::InvalidSignature) { wrong_policy.verify!(legacy, "original typed proof") }
    assert_equal "current", enabled.sign("new typed proof").fetch("key_id")
  end

  test "keyring configuration rejects malformed oversized and unknown key settings without exposing values" do
    valid = Base64.strict_encode64("a" * 32)
    cases = [
      { active_key_id: "absent", keys: {} },
      { active_key_id: "", keys: { "first" => valid } },
      { keys: { "invalid/id" => valid } },
      { keys: { "first" => "private-malformed-secret" } },
      { keys: { "first" => Base64.strict_encode64("a" * 31) } },
      { keys: Array.new(33) { |index| [ "key-#{index}", valid ] }.to_h },
      { keys: " " * (Keys::MAX_CONFIG_BYTES + 1) },
      { keys: "private-invalid-json" },
      { "keys" => {}, keys: {} },
      { keys: {}, unexpected: "private-config-field" }
    ]

    cases.each do |configuration|
      error = assert_raises(Keys::InvalidConfiguration) { Keys.new(configuration) }
      assert_not_includes error.message, "private-"
      assert_not_includes error.message, valid
    end
  end

  test "JSON configuration and retained key snapshots are immutable and do not expose key material" do
    encoded = Base64.strict_encode64("private-test-key".ljust(32, "0"))
    input = { "first" => encoded }
    keys = Keys.new(active_key_id: "first", keys: input)
    signature = keys.sign("proof")
    assert_equal signature, Keys.new(active_key_id: "first", keys: JSON.generate(input)).sign("proof")
    input["first"].replace(Base64.strict_encode64("x" * 32))

    assert keys.verify!(signature, "proof")
    assert_not_includes keys.inspect, "private-test-key"
    assert_not_includes keys.inspect, encoded
    assert_match(/\A[0-9a-f]{64}\z/, keys.cache_token)
  end

  private
    def keyring(active:, keys:, legacy: nil)
      Keys.new(active_key_id: active, keys: keys.transform_values { |key| Base64.strict_encode64(key) }, legacy_v1_key_id: legacy)
    end
end
