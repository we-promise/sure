# frozen_string_literal: true

require "test_helper"

class ActiveRecordEncryptionConfigTest < ActiveSupport::TestCase
  test "fresh application boot installs normalized encryption compatibility" do
    assert_includes $LOADED_FEATURES, Rails.root.join("lib/normalized_encryption_compatibility.rb").to_s
    assert_equal NormalizedEncryptionCompatibility::SUPPORTED_VERSION, ActiveRecord.version.to_s
    assert_equal NormalizedEncryptionCompatibility::NormalizedCast,
      ActiveModel::Attributes::Normalization::NormalizedValueType.instance_method(:cast).owner

    configured = ActiveRecordEncryptionConfig.explicitly_configured?
    assert_equal configured, User.encryption_ready?
    assert_equal configured, Array(User.encrypted_attributes).include?(:email)

    case ENV["SURE_ENCRYPTION_TEST_MODE"]
    when "off"
      assert_not configured
      assert_not ActiveRecordEncryptionConfig.complete_env?
    when "encrypted", "compatible"
      assert ActiveRecordEncryptionConfig.complete_env?
      assert configured
      compatible = ENV["SURE_ENCRYPTION_TEST_MODE"] == "compatible"
      assert_equal compatible, ActiveRecord::Encryption.config.support_unencrypted_data
      assert_equal compatible, ActiveRecord::Encryption.config.extend_queries
    when nil
      # Ordinary suite runs verify the actual booted attribute configuration.
    else
      flunk "Unknown SURE_ENCRYPTION_TEST_MODE"
    end
  end

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
end
