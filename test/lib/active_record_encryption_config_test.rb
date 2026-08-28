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

  test "detects complete credentials configuration" do
    encryption_config = OpenStruct.new(primary_key: "primary", deterministic_key: "deterministic", key_derivation_salt: "salt")
    credentials = OpenStruct.new(active_record_encryption: encryption_config)

    assert ActiveRecordEncryptionConfig.credentials_configured?(credentials)
  end

  test "does not treat partial credentials as configured" do
    encryption_config = OpenStruct.new(primary_key: "primary", deterministic_key: nil, key_derivation_salt: "salt")
    credentials = OpenStruct.new(active_record_encryption: encryption_config)

    refute ActiveRecordEncryptionConfig.credentials_configured?(credentials)
    assert ActiveRecordEncryptionConfig.partial_credentials?(credentials)
    assert_equal [ :deterministic_key ], ActiveRecordEncryptionConfig.missing_credential_keys(credentials)
    assert_includes ActiveRecordEncryptionConfig.partial_credentials_message(credentials), "deterministic_key"
  end

  test "does not treat absent encryption credentials as partial" do
    credentials = OpenStruct.new(active_record_encryption: nil)

    refute ActiveRecordEncryptionConfig.credentials_configured?(credentials)
    refute ActiveRecordEncryptionConfig.partial_credentials?(credentials)
  end

  # Regression test for a gap CodeRabbit flagged: a present credentials block
  # with every individual key blank had present_count == 0, so the old
  # `present_count.positive? && ...` shape treated it the same as an absent
  # block (not partial) - silently skipping both the raise and self-hosted
  # auto-generation, since config/application.rb's `.present?` check on the
  # block itself already treats it as configured either way.
  test "treats a present credentials block with every key blank as partial" do
    encryption_config = OpenStruct.new(primary_key: "", deterministic_key: "", key_derivation_salt: "")
    credentials = OpenStruct.new(active_record_encryption: encryption_config)

    refute ActiveRecordEncryptionConfig.credentials_configured?(credentials)
    assert ActiveRecordEncryptionConfig.partial_credentials?(credentials)
    assert_equal ActiveRecordEncryptionConfig::CONFIG_KEYS, ActiveRecordEncryptionConfig.missing_credential_keys(credentials)
  end

  test "does not treat complete encryption credentials as partial" do
    encryption_config = OpenStruct.new(primary_key: "primary", deterministic_key: "deterministic", key_derivation_salt: "salt")
    credentials = OpenStruct.new(active_record_encryption: encryption_config)

    assert ActiveRecordEncryptionConfig.credentials_configured?(credentials)
    refute ActiveRecordEncryptionConfig.partial_credentials?(credentials)
  end

  test "apply_keys! copies keys onto both the given config and the live ActiveRecord::Encryption engine" do
    ActiveRecord::Encryption.config.expects(:primary_key=).with("pk")
    ActiveRecord::Encryption.config.expects(:deterministic_key=).with("dk")
    ActiveRecord::Encryption.config.expects(:key_derivation_salt=).with("salt")

    rails_config = OpenStruct.new

    ActiveRecordEncryptionConfig.apply_keys!(
      primary_key: "pk", deterministic_key: "dk", key_derivation_salt: "salt", config: rails_config
    )

    assert_equal "pk", rails_config.primary_key
    assert_equal "dk", rails_config.deterministic_key
    assert_equal "salt", rails_config.key_derivation_salt
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

  test "using_known_compromised_secret_key_base? is true regardless of explicit AR encryption keys" do
    # SECRET_KEY_BASE also signs/encrypts Rails session cookies and is the
    # sole key source for Setting's own encryptor (app/models/setting.rb),
    # independently of ActiveRecord Encryption. An install with its own
    # explicit AR keys is unaffected on the AR-encryption front, but its
    # sessions and Setting-stored values (AI/market-data provider API keys)
    # remain just as crackable, so this must not be suppressed by
    # explicitly_configured? - see config/initializers/encryption_warning.rb
    # for how the two concerns are reported separately.
    known_default = ActiveRecordEncryptionConfig::KNOWN_COMPROMISED_SECRET_KEY_BASES.first
    ActiveRecordEncryptionConfig.stubs(:explicitly_configured?).returns(true)

    assert ActiveRecordEncryptionConfig.using_known_compromised_secret_key_base?(known_default)
  end

  test "backfill_completed? is false before any backfill has run" do
    Setting.encryption_backfill_completed_version = 0

    refute ActiveRecordEncryptionConfig.backfill_completed?
  end

  test "backfill_completed? is true once the stored version meets the required version" do
    Setting.encryption_backfill_completed_version = ActiveRecordEncryptionConfig::CURRENT_BACKFILL_VERSION

    assert ActiveRecordEncryptionConfig.backfill_completed?
  end

  test "backfill_completed? is false when the stored version predates a coverage expansion" do
    # Simulates an install that completed a backfill under an older, narrower
    # CURRENT_BACKFILL_VERSION before upgrading to code that covers more
    # models/fields - it must not be treated as complete until it re-runs
    # the task, or the fallback gets disabled for newly-covered models that
    # were never actually backfilled.
    Setting.encryption_backfill_completed_version = 1

    refute ActiveRecordEncryptionConfig.backfill_completed?(required_version: 2)
  end

  test "backfill_completed? defaults to false when the settings table can't be read" do
    # backfill_completed? deliberately bypasses the Setting model (see its
    # comment for why) and queries the settings table directly via
    # ActiveRecord::Base.connection.select_value - stubbing Setting itself,
    # as a previous version of this test did, never exercises the real
    # rescue path at all since that method is never called.
    ActiveRecord::Base.connection.stubs(:select_value).raises(ActiveRecord::StatementInvalid, "relation \"settings\" does not exist")

    refute ActiveRecordEncryptionConfig.backfill_completed?
  end

  test "backfill_completed? defaults to false when the stored value isn't a YAML-serialized Integer" do
    ActiveRecord::Base.connection.stubs(:select_value).returns("not_an_integer")

    refute ActiveRecordEncryptionConfig.backfill_completed?
  end

  test "backfill_completed? defaults to false when the stored value is malformed YAML" do
    ActiveRecord::Base.connection.stubs(:select_value).raises(Psych::Exception, "malformed yaml")

    refute ActiveRecordEncryptionConfig.backfill_completed?
  end
end
