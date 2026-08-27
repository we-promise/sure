# frozen_string_literal: true

require "test_helper"

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
end
