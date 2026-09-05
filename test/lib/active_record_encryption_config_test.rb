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

  test "detects complete previous-key rotation environment" do
    env = {
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY_PREVIOUS" => "primary",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY_PREVIOUS" => "deterministic",
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT_PREVIOUS" => "salt"
    }

    assert ActiveRecordEncryptionConfig.complete_previous_env?(env)
    refute ActiveRecordEncryptionConfig.partial_previous_env?(env)
    assert_empty ActiveRecordEncryptionConfig.missing_previous_env_keys(env)
  end

  test "detects partially configured previous-key rotation environment" do
    env = {
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY_PREVIOUS" => "primary",
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY_PREVIOUS" => nil,
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT_PREVIOUS" => "salt"
    }

    refute ActiveRecordEncryptionConfig.complete_previous_env?(env)
    assert ActiveRecordEncryptionConfig.partial_previous_env?(env)
    assert_equal [ "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY_PREVIOUS" ], ActiveRecordEncryptionConfig.missing_previous_env_keys(env)
    assert_includes ActiveRecordEncryptionConfig.partial_previous_env_message(env), "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY_PREVIOUS"
  end

  test "does not treat absent previous-key rotation environment as partial" do
    env = {
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY_PREVIOUS" => nil,
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY_PREVIOUS" => nil,
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT_PREVIOUS" => nil
    }

    refute ActiveRecordEncryptionConfig.complete_previous_env?(env)
    refute ActiveRecordEncryptionConfig.partial_previous_env?(env)
  end

  test "using_known_compromised_secret_key_base? is true even when explicit AR keys are configured" do
    # explicitly_configured? (env vars or credentials) only means AR
    # encryption's own keys aren't derived from SECRET_KEY_BASE - it says
    # nothing about session cookies or Setting's own encryptor
    # (app/models/setting.rb), which are always keyed directly off
    # SECRET_KEY_BASE regardless of AR encryption config. A known-compromised
    # SECRET_KEY_BASE still exposes those even with explicit AR keys, so this
    # must NOT be suppressed - see encryption_warning.rb for how the two
    # cases (auto-derived vs explicitly-configured AR keys) get different
    # guidance instead.
    known_default = ActiveRecordEncryptionConfig::KNOWN_COMPROMISED_SECRET_KEY_BASES.first
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)

    assert ActiveRecordEncryptionConfig.using_known_compromised_secret_key_base?(known_default)
  end
end
