# frozen_string_literal: true

require "test_helper"
require "open3"

class ActiveRecordEncryptionConfigTest < ActiveSupport::TestCase
  test "detects complete encryption environment" do
    env = {
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "primary",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "deterministic",
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "salt"
    }

    assert ActiveRecordEncryptionConfig.complete_env?(env)
    refute ActiveRecordEncryptionConfig.partial_env?(env)
    assert_empty ActiveRecordEncryptionConfig.missing_env_keys(env)
  end

  test "detects partially configured encryption environment" do
    env = {
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "primary",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => nil,
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "salt"
    }

    refute ActiveRecordEncryptionConfig.complete_env?(env)
    assert ActiveRecordEncryptionConfig.partial_env?(env)
    assert_equal [ "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" ], ActiveRecordEncryptionConfig.missing_env_keys(env)
    assert_includes ActiveRecordEncryptionConfig.partial_env_message(env), "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"
  end

  test "does not treat absent encryption environment as partial" do
    env = {
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => nil,
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => nil,
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => nil
    }

    refute ActiveRecordEncryptionConfig.complete_env?(env)
    refute ActiveRecordEncryptionConfig.partial_env?(env)
  end

  test "detects runtime encryption configuration" do
    config = Struct.new(:primary_key, :deterministic_key, :key_derivation_salt).new("primary", "deterministic", "salt")

    assert ActiveRecordEncryptionConfig.runtime_configured?(config)
  end

  test "explicit configuration excludes runtime generated config" do
    ActiveRecordEncryptionConfig.stubs(:complete_env?).returns(false)
    ActiveRecordEncryptionConfig.stubs(:credentials_configured?).returns(false)
    ActiveRecordEncryptionConfig.stubs(:runtime_configured?).returns(true)

    refute ActiveRecordEncryptionConfig.explicitly_configured?
    assert ActiveRecordEncryptionConfig.ready?
  end

  test "detects a secret key base that was previously shipped as a compose default" do
    known_default = ActiveRecordEncryptionConfig::KNOWN_COMPROMISED_SECRET_KEY_BASES.first

    assert ActiveRecordEncryptionConfig.using_known_compromised_secret_key_base?(known_default)
    refute ActiveRecordEncryptionConfig.using_known_compromised_secret_key_base?("a-real-generated-secret")
  end

  test "using_known_compromised_secret_key_base? defaults to the app's own secret_key_base" do
    Rails.application.stubs(:secret_key_base).returns(ActiveRecordEncryptionConfig::KNOWN_COMPROMISED_SECRET_KEY_BASES.first)
    assert ActiveRecordEncryptionConfig.using_known_compromised_secret_key_base?

    Rails.application.stubs(:secret_key_base).returns("a-real-generated-secret")
    refute ActiveRecordEncryptionConfig.using_known_compromised_secret_key_base?
  end

  test "using_known_compromised_secret_key_base? is false when explicit keys are configured" do
    # explicitly_configured? (env vars or credentials) takes precedence over
    # SECRET_KEY_BASE in config/initializers/active_record_encryption.rb, so
    # an install with its own explicit keys is unaffected even if it still
    # has this SECRET_KEY_BASE value lying around (e.g. never rotated it
    # because it isn't actually the key source).
    known_default = ActiveRecordEncryptionConfig::KNOWN_COMPROMISED_SECRET_KEY_BASES.first
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)

    refute ActiveRecordEncryptionConfig.using_known_compromised_secret_key_base?(known_default)
  end

  test "derived_keys returns the keys derived from SECRET_KEY_BASE" do
    keys = ActiveRecordEncryptionConfig.derived_keys("old-base")

    assert_equal Digest::SHA256.hexdigest("old-base:primary_key")[0..63], keys[:primary_key]
    assert_equal Digest::SHA256.hexdigest("old-base:deterministic_key")[0..63], keys[:deterministic_key]
    assert_equal Digest::SHA256.hexdigest("old-base:key_derivation_salt")[0..63], keys[:key_derivation_salt]
  end

  test "previous_schemes is empty without a previous SECRET_KEY_BASE" do
    assert_empty ActiveRecordEncryptionConfig.previous_schemes({})
    assert_empty ActiveRecordEncryptionConfig.previous_schemes(ActiveRecordEncryptionConfig::PREVIOUS_SECRET_KEY_BASE_ENV => "")
  end

  # The old salt differs from the configured one, which Rails' own key
  # providers would use.
  test "previous_schemes decrypt data encrypted with keys derived from an old SECRET_KEY_BASE" do
    old_base = SecureRandom.hex(64)
    texts = encrypt_as_derived_from(old_base, "nd-secret", "det-secret")

    schemes = ActiveRecordEncryptionConfig.previous_schemes(ActiveRecordEncryptionConfig::PREVIOUS_SECRET_KEY_BASE_ENV => old_base)
    non_deterministic = schemes.find { |scheme| !scheme[:deterministic] }
    deterministic = schemes.find { |scheme| scheme[:deterministic] }
    encryptor = ActiveRecord::Encryption.encryptor

    assert_equal "nd-secret", encryptor.decrypt(texts[:non_deterministic], key_provider: non_deterministic[:key_provider])
    assert_equal "det-secret", encryptor.decrypt(texts[:deterministic], key_provider: deterministic[:key_provider])
  end

  # Boots the app the way an operator's one-off command does, so the
  # initializer wiring and Rails' merge of global previous schemes into each
  # encrypted attribute are covered.
  test "an old SECRET_KEY_BASE in the environment makes old data readable through the models" do
    old_base = SecureRandom.hex(64)
    texts = encrypt_as_derived_from(old_base, "Ada", "old-key@example.com")
    script = <<~RUBY
      puts User.type_for_attribute(:first_name).deserialize(ENV.fetch("PROBE_ND"))
      puts User.type_for_attribute(:email).deserialize(ENV.fetch("PROBE_DET"))
    RUBY
    env = {
      ActiveRecordEncryptionConfig::PREVIOUS_SECRET_KEY_BASE_ENV => old_base,
      "PROBE_ND" => texts[:non_deterministic],
      "PROBE_DET" => texts[:deterministic]
    }

    output, status = Open3.capture2e(env, Rails.root.join("bin/rails").to_s, "runner", script, chdir: Rails.root.to_s)

    assert status.success?, output
    assert_equal [ "Ada", "old-key@example.com" ], output.lines.last(2).map(&:strip)
  end

  private

    # Encrypts like an install whose keys were derived from old_base: Rails'
    # key providers with that install's salt as the configured one. A fresh
    # KeyGenerator reads the salt on first use; the shared one has it cached.
    def encrypt_as_derived_from(old_base, non_deterministic_text, deterministic_text)
      keys = ActiveRecordEncryptionConfig.derived_keys(old_base)
      config = ActiveRecord::Encryption.config
      original_salt = config.key_derivation_salt
      config.key_derivation_salt = keys[:key_derivation_salt]
      non_deterministic = ActiveRecord::Encryption::DerivedSecretKeyProvider.new(
        keys[:primary_key], key_generator: ActiveRecord::Encryption::KeyGenerator.new)
      deterministic = ActiveRecord::Encryption::DerivedSecretKeyProvider.new(
        keys[:deterministic_key], key_generator: ActiveRecord::Encryption::KeyGenerator.new)
      config.key_derivation_salt = original_salt

      encryptor = ActiveRecord::Encryption.encryptor
      {
        non_deterministic: encryptor.encrypt(non_deterministic_text, key_provider: non_deterministic),
        deterministic: encryptor.encrypt(deterministic_text, key_provider: deterministic, cipher_options: { deterministic: true })
      }
    ensure
      config.key_derivation_salt = original_salt
    end
end
