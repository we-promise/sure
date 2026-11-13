# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261113130000_promote_plaid_secrets_to_declared_settings")

class PromotePlaidSecretsToDeclaredSettingsMigrationTest < ActiveSupport::TestCase
  setup do
    Setting.where(var: %w[plaid_secret plaid_eu_secret dynamic:plaid_secret dynamic:plaid_eu_secret]).delete_all
    Setting.clear_cache
  end

  test "moves both legacy secrets into encrypted declared settings without changing the UI read path" do
    %w[plaid_secret plaid_eu_secret].each { |key| store_legacy(key, "synthetic-#{key}") }
    ids = Setting.where("var LIKE ?", "dynamic:plaid%secret").pluck(:id).sort
    Setting.plaid_secret # Populate the declared-setting cache before conversion.

    run_migration

    %w[plaid_secret plaid_eu_secret].each do |key|
      assert_equal "synthetic-#{key}", Setting[key]
      refute_includes Setting.find_by!(var: key).value, "synthetic-#{key}"
      assert_not Setting.exists?(var: "dynamic:#{key}")
    end
    assert_equal ids, Setting.where(var: %w[plaid_secret plaid_eu_secret]).pluck(:id).sort
    assert_equal "synthetic-plaid_secret", Provider::PlaidAdapter.config_value(:secret)
    assert_equal "synthetic-plaid_eu_secret", Provider::PlaidEuAdapter.config_value(:secret)
  end

  test "does nothing on fresh and ENV-only installations" do
    Rails.application.expects(:secret_key_base).never
    with_env_overrides("PLAID_SECRET" => "synthetic-env-secret", "PLAID_EU_SECRET" => "synthetic-eu-env-secret") do
      run_migration

      assert_equal "synthetic-env-secret", Provider::PlaidAdapter.config_value(:secret)
      assert_equal "synthetic-eu-env-secret", Provider::PlaidEuAdapter.config_value(:secret)
      assert_empty Setting.where(var: %w[plaid_secret plaid_eu_secret])
    end
  end

  test "reruns do not rewrite already converted secrets" do
    store_legacy("plaid_secret", "synthetic-secret")
    run_migration
    ciphertext = Setting.find_by!(var: "plaid_secret").value

    run_migration

    assert_equal ciphertext, Setting.find_by!(var: "plaid_secret").value
    assert_equal "synthetic-secret", Setting.plaid_secret
  end

  test "preserves empty legacy values and unrelated dynamic settings" do
    store_legacy("plaid_secret", "")
    store_legacy("plaid_eu_secret", nil)
    Setting[:plaid_client_id] = "synthetic-client"
    Setting[:custom_value] = "ordinary-value"

    run_migration

    assert_equal "", Setting.find_by!(var: "plaid_secret").value
    assert_nil Setting.find_by!(var: "plaid_eu_secret").value
    assert_equal "synthetic-client", Setting[:plaid_client_id]
    assert_equal "ordinary-value", Setting[:custom_value]
    assert_empty Setting.where(var: %w[dynamic:plaid_secret dynamic:plaid_eu_secret])
  end

  test "missing key blocks conversion rather than moving credentials as plaintext" do
    store_legacy("plaid_secret", "synthetic-secret")
    Rails.application.stubs(:secret_key_base).returns(nil)

    error = assert_raises(PromotePlaidSecretsToDeclaredSettings::ConversionError) { run_migration }

    assert_includes error.message, "SECRET_KEY_BASE is required"
    assert_equal "synthetic-secret", Setting.find_by!(var: "dynamic:plaid_secret").value
    assert_not Setting.exists?(var: "plaid_secret")
  end

  test "conflicts stop conversion and roll back the other region" do
    store_legacy("plaid_secret", "synthetic-us-secret")
    store_legacy("plaid_eu_secret", "synthetic-eu-secret")
    Setting.plaid_eu_secret = "synthetic-existing-secret"
    existing = Setting.find_by!(var: "plaid_eu_secret").value

    assert_raises(PromotePlaidSecretsToDeclaredSettings::ConversionError) { run_migration }

    assert_equal "synthetic-us-secret", Setting.find_by!(var: "dynamic:plaid_secret").value
    assert_equal "synthetic-eu-secret", Setting.find_by!(var: "dynamic:plaid_eu_secret").value
    assert_not Setting.exists?(var: "plaid_secret")
    assert_equal existing, Setting.find_by!(var: "plaid_eu_secret").value
  end

  test "unexpected legacy formats stop conversion instead of encrypting an envelope or hash" do
    store_legacy("plaid_secret", "synthetic-us-secret")
    store_legacy("plaid_eu_secret", { "sure_provider_secret" => 1, "ciphertext" => "synthetic-envelope" })

    error = assert_raises(PromotePlaidSecretsToDeclaredSettings::ConversionError) { run_migration }

    assert_includes error.message, "not a plaintext string"
    refute_includes error.message, "synthetic-envelope"
    assert_not Setting.exists?(var: "plaid_secret")
    assert Setting.exists?(var: "dynamic:plaid_secret")
    assert Setting.exists?(var: "dynamic:plaid_eu_secret")
  end

  test "encryption failures preserve both sources and hide sensitive error messages" do
    store_legacy("plaid_secret", "synthetic-us-secret")
    store_legacy("plaid_eu_secret", "synthetic-eu-secret")
    migration = PromotePlaidSecretsToDeclaredSettings.new
    encryptor = mock("encryptor")
    encryptor.expects(:encrypt_and_sign).with("synthetic-us-secret").returns("synthetic-ciphertext")
    encryptor.expects(:encrypt_and_sign).with("synthetic-eu-secret").raises(StandardError, "synthetic-sensitive-details")
    migration.stubs(:encryptor).returns(encryptor)

    error = assert_raises(PromotePlaidSecretsToDeclaredSettings::ConversionError) { migration.up }

    refute_includes error.message, "synthetic-sensitive-details"
    assert_nil error.cause
    assert_equal "synthetic-us-secret", Setting.find_by!(var: "dynamic:plaid_secret").value
    assert_equal "synthetic-eu-secret", Setting.find_by!(var: "dynamic:plaid_eu_secret").value
    assert_empty Setting.where(var: %w[plaid_secret plaid_eu_secret])
  end

  test "conversion does not log credential values or ciphertext" do
    store_legacy("plaid_secret", "synthetic-sensitive-secret")
    output = StringIO.new
    original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(output)

    run_migration

    refute_includes output.string, "synthetic-sensitive-secret"
    refute_includes output.string, Setting.find_by!(var: "plaid_secret").value
  ensure
    ActiveRecord::Base.logger = original_logger
  end

  test "conversion works without an Active Record logger" do
    store_legacy("plaid_secret", "synthetic-secret")
    original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = nil

    run_migration

    assert_equal "synthetic-secret", Setting.plaid_secret
    assert_not Setting.exists?(var: "dynamic:plaid_secret")
  ensure
    ActiveRecord::Base.logger = original_logger
  end

  test "rollback cannot restore plaintext credentials" do
    assert_raises(ActiveRecord::IrreversibleMigration) do
      PromotePlaidSecretsToDeclaredSettings.new.down
    end
  end

  private

    def store_legacy(key, value)
      Setting.create!(var: "dynamic:#{key}", value: value)
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        PromotePlaidSecretsToDeclaredSettings.new.migrate(:up)
      end
    end
end
