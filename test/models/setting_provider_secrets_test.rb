require "test_helper"
require "open3"

class SettingProviderSecretsTest < ActiveSupport::TestCase
  test "dynamic Plaid secret is encrypted in raw storage and round trips" do
    secret = "synthetic-plaid-regression-secret"
    Setting[:plaid_secret] = secret

    refute_includes raw_value, secret
    assert_equal secret, Setting[:plaid_secret]
    assert_equal secret, Provider::PlaidAdapter.config_value(:secret)
  end

  test "another registered dynamic secret is encrypted" do
    Setting[:plaid_eu_secret] = "synthetic-eu-secret"
    raw = Setting.connection.select_value("SELECT value FROM settings WHERE var = 'dynamic:plaid_eu_secret'")
    refute_includes raw, "synthetic-eu-secret"
    assert_equal "synthetic-eu-secret", Provider::PlaidEuAdapter.config_value(:secret)
  end

  test "fresh process loads secret metadata without a controller" do
    # Regression: secret metadata lookup failed before another test loaded the adapters.
    script = <<~RUBY
      abort "eager loading enabled" if Rails.application.config.eager_load
      envelope = Setting::DynamicSecret.encrypt("plaid_secret", "synthetic-process-secret")
      abort "round trip failed" unless Setting::DynamicSecret.decrypt("plaid_secret", envelope) == "synthetic-process-secret"
      keys = Provider::ConfigurationRegistry.secret_setting_keys
      abort "missing metadata" unless keys.include?("plaid_secret") && keys.include?("plaid_eu_secret")
      puts "provider-secret-check-ok"
    RUBY
    output, error, status = Open3.capture3({ "RAILS_ENV" => "test", "CI" => nil }, "bin/rails", "runner", script)
    assert status.success?, "Fresh-process metadata/encryption check failed: #{error}"
    assert_includes output, "provider-secret-check-ok"
  end

  test "metadata loading failure prevents plaintext writes" do
    Provider::ConfigurationRegistry.expects(:field_for_setting).with("plaid_secret").raises(Setting::SecretError)
    assert_raises(Setting::SecretError) { Setting[:plaid_secret] = "synthetic-secret" }
    assert_not Setting.key?(:plaid_secret)
  end

  test "legacy reads do not rewrite storage" do
    store_legacy("synthetic-legacy-secret")
    before = raw_value
    assert_equal "synthetic-legacy-secret", Setting[:plaid_secret]
    assert_equal before, raw_value
  end

  test "dynamic writes do not load unrelated adapters" do
    Provider::PlaidAdapter
    pattern = Rails.root.join("app/models/provider/*_adapter.rb")
    Dir.stubs(:[]).with(pattern).returns(%w[plaid missing].map { |name| Rails.root.join("app/models/provider/#{name}_adapter.rb").to_s })
    Provider::Factory.expects(:ensure_adapters_loaded).never
    Provider::ConfigurationRegistry.expects(:secret_setting_keys).never
    Setting[:plaid_client_id] = "synthetic-client"
    Setting[:plaid_secret] = "synthetic-secret"
    Setting[:custom_value] = "ordinary"

    assert_equal "synthetic-client", Setting[:plaid_client_id]
    assert_equal "synthetic-secret", Setting[:plaid_secret]
    refute_includes raw_value, "synthetic-secret"
    assert_equal "ordinary", Setting[:custom_value]
  end

  test "owning adapter metadata failures log the adapter without sensitive messages" do
    pattern = Rails.root.join("app/models/provider/*_adapter.rb")
    Dir.expects(:[]).with(pattern).returns([ Rails.root.join("app/models/provider/missing_adapter.rb").to_s ])
    Rails.logger.expects(:error).with("Provider secret metadata unavailable: adapter=Provider::MissingAdapter error=NameError")

    error = assert_raises(Setting::SecretError) { Setting[:missing_secret] = "synthetic-secret" }
    assert_nil error.cause
    assert_not Setting.key?(:missing_secret)
  end

  test "writes and backfill work without an Active Record logger" do
    store_legacy("synthetic-legacy-secret")
    original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = nil

    assert_equal 1, Setting::ProviderSecretBackfill.call(dry_run: false)[:encrypted]
    assert_equal "synthetic-legacy-secret", Setting[:plaid_secret]
    refute_includes raw_value, "synthetic-legacy-secret"
  ensure
    ActiveRecord::Base.logger = original_logger
  end

  test "envelopes fail closed on corruption unknown version and extra fields" do
    Setting[:plaid_secret] = "synthetic-secret"
    envelope = Setting.find_by!(var: "dynamic:plaid_secret").value
    [ envelope.merge("ciphertext" => "truncated"),
      envelope.merge(Setting::DynamicSecret::MARKER => 2),
      envelope.merge("unexpected" => "data") ].each do |invalid|
      store_legacy(invalid)
      before = raw_value
      error = assert_raises(Setting::SecretError) { Provider::PlaidAdapter.config_value(:secret) }
      assert_equal Setting::DynamicSecret::ERROR_MESSAGE, error.message
      assert_nil error.cause
      assert_equal before, raw_value
    end
  end

  test "wrong key does not return ciphertext or fall back to ENV" do
    Setting[:plaid_secret] = "synthetic-secret"
    other_encryptor = ActiveSupport::MessageEncryptor.new("x" * 32)
    Setting.stubs(:setting_encryptor).returns(other_encryptor)
    with_env_overrides("PLAID_SECRET" => "synthetic-env-secret") do
      assert_raises(Setting::SecretError) { Provider::PlaidAdapter.config_value(:secret) }
    end
  end

  test "envelopes cannot be moved between settings" do
    Setting[:plaid_secret] = "synthetic-secret"
    envelope = Setting.find_by!(var: "dynamic:plaid_secret").value
    Setting.upsert({ var: "dynamic:plaid_eu_secret", value: envelope.to_yaml }, unique_by: :var)
    assert_raises(Setting::SecretError) { Setting[:plaid_eu_secret] }
  end

  test "unusable key prevents writes rather than storing plaintext" do
    Setting.stubs(:setting_encryptor).raises(ArgumentError, "synthetic-sensitive-error")
    error = assert_raises(Setting::SecretError) { Setting[:plaid_secret] = "synthetic-secret" }
    assert_equal Setting::DynamicSecret::ERROR_MESSAGE, error.message
    assert_not Setting.key?(:plaid_secret)
  end

  test "ordinary types empty values and deletion retain their behavior" do
    [ true, 42, [ "value" ], { "name" => "value" } ].each do |value|
      Setting[:custom_value] = value
      assert_equal value, Setting[:custom_value]
    end
    Setting[:plaid_secret] = ""
    assert_equal "", Setting[:plaid_secret]
    Setting[:plaid_secret] = "  synthetic-secret  "
    assert_equal "  synthetic-secret  ", Setting[:plaid_secret]
    assert_equal "synthetic-secret", Provider::PlaidAdapter.config_value(:secret)
    Setting[:plaid_secret] = nil
    assert_not Setting.key?(:plaid_secret)
  end

  test "ENV fallback is not persisted and stored secrets take precedence" do
    with_env_overrides("PLAID_SECRET" => "synthetic-env-secret") do
      assert_equal "synthetic-env-secret", Provider::PlaidAdapter.config_value(:secret)
      assert_not Setting.key?(:plaid_secret)
      Setting[:plaid_secret] = "synthetic-stored-secret"
      assert_equal "synthetic-stored-secret", Provider::PlaidAdapter.config_value(:secret)
    end
  end

  test "backfill is count only by default and idempotent when applied" do
    store_legacy("synthetic-legacy-secret")
    before = raw_value
    counts = Setting::ProviderSecretBackfill.call
    assert_equal 1, counts[:candidates]
    assert_equal 0, counts[:encrypted]
    assert_equal before, raw_value

    counts = Setting::ProviderSecretBackfill.call(dry_run: false)
    assert_equal 1, counts[:encrypted]
    refute_includes raw_value, "synthetic-legacy-secret"
    assert_equal "synthetic-legacy-secret", Setting[:plaid_secret]
    encrypted = raw_value
    counts = Setting::ProviderSecretBackfill.call(dry_run: false)
    assert_equal 0, counts[:encrypted]
    assert_equal 1, counts[:unchanged]
    assert_equal encrypted, raw_value
  end

  test "backfill counts invalid envelopes without rewriting and preserves progress" do
    store_legacy({ Setting::DynamicSecret::MARKER => 1, "ciphertext" => "broken" })
    before = raw_value
    row = Setting.find_by!(var: "dynamic:plaid_secret")
    Rails.logger.expects(:error).with("Provider secret backfill failed: id=#{row.id} var=dynamic:plaid_secret error=Setting::SecretError").twice
    Setting.upsert({ var: "dynamic:plaid_eu_secret", value: "synthetic-eu-secret".to_yaml }, unique_by: :var)
    counts = Setting::ProviderSecretBackfill.call(dry_run: false)
    assert_equal 1, counts[:failed]
    assert_equal 1, counts[:encrypted]
    assert_equal before, raw_value
    assert_equal "synthetic-eu-secret", Setting[:plaid_eu_secret]
    assert_equal 0, Setting::ProviderSecretBackfill.call(dry_run: false)[:encrypted]
  end

  test "backfill persistence failures log identifiers without values or exception messages" do
    store_legacy("synthetic-sensitive-secret")
    before = raw_value
    row = Setting.find_by!(var: "dynamic:plaid_secret")
    Setting.expects(:[]=).with("plaid_secret", "synthetic-sensitive-secret")
      .raises(StandardError.new("synthetic-sensitive-error-details"))
    Rails.logger.expects(:error).with("Provider secret backfill failed: id=#{row.id} var=dynamic:plaid_secret error=StandardError").once

    counts = Setting::ProviderSecretBackfill.call(dry_run: false)

    assert_equal 1, counts[:failed]
    assert_equal 0, counts[:encrypted]
    assert_equal before, raw_value
  end

  test "dynamic upsert does not log secrets or ciphertext" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    original_logger = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = logger
    Setting[:plaid_secret] = "synthetic-log-secret"
    refute_includes output.string, "synthetic-log-secret"
    refute_includes output.string, "ciphertext"
  ensure
    ActiveRecord::Base.logger = original_logger
  end

  private
    def store_legacy(value)
      Setting.upsert({ var: "dynamic:plaid_secret", value: value.to_yaml }, unique_by: :var)
    end

    def raw_value
      Setting.connection.select_value("SELECT value FROM settings WHERE var = 'dynamic:plaid_secret'")
    end
end
