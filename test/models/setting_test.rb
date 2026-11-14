require "test_helper"

class SettingTest < ActiveSupport::TestCase
  setup do
    # Clear settings before each test
    Setting.openai_uri_base = nil
    Setting.openai_model = nil
  end

  teardown do
    # Clean up dynamic fields after each test
    Setting.where("var LIKE ?", "dynamic:%").destroy_all
  end

  test "validate_openai_config! passes when both uri base and model are set" do
    assert_nothing_raised do
      Setting.validate_openai_config!(uri_base: "https://api.example.com", model: "gpt-4")
    end
  end

  test "validate_openai_config! passes when neither uri base nor model are set" do
    assert_nothing_raised do
      Setting.validate_openai_config!(uri_base: "", model: "")
    end
  end

  test "validate_openai_config! passes when uri base is blank and model is set" do
    assert_nothing_raised do
      Setting.validate_openai_config!(uri_base: "", model: "gpt-4")
    end
  end

  test "validate_openai_config! raises error when uri base is set but model is blank" do
    error = assert_raises(Setting::ValidationError) do
      Setting.validate_openai_config!(uri_base: "https://api.example.com", model: "")
    end

    assert_match(/OpenAI model is required/, error.message)
  end

  test "validate_openai_config! passes for a regional OpenAI host without a model" do
    assert_nothing_raised do
      Setting.validate_openai_config!(uri_base: "https://us.api.openai.com", model: "")
    end
  end

  test "validate_openai_config! uses current settings when parameters are nil" do
    Setting.openai_uri_base = "https://api.example.com"
    Setting.openai_model = "gpt-4"

    assert_nothing_raised do
      Setting.validate_openai_config!(uri_base: nil, model: nil)
    end
  end

  test "validate_openai_config! raises error when current uri base is set but new model is blank" do
    Setting.openai_uri_base = "https://api.example.com"
    Setting.openai_model = "gpt-4"

    error = assert_raises(Setting::ValidationError) do
      Setting.validate_openai_config!(uri_base: nil, model: "")
    end

    assert_match(/OpenAI model is required/, error.message)
  end

  test "validate_openai_config! passes when new uri base is blank and current model exists" do
    Setting.openai_uri_base = "https://api.example.com"
    Setting.openai_model = "gpt-4"

    assert_nothing_raised do
      Setting.validate_openai_config!(uri_base: "", model: nil)
    end
  end

  # Dynamic field tests
  test "can set and get dynamic fields" do
    Setting["custom_key"] = "custom_value"
    assert_equal "custom_value", Setting["custom_key"]
  end

  test "can set and get multiple dynamic fields independently" do
    Setting["key1"] = "value1"
    Setting["key2"] = "value2"
    Setting["key3"] = "value3"

    assert_equal "value1", Setting["key1"]
    assert_equal "value2", Setting["key2"]
    assert_equal "value3", Setting["key3"]
  end

  test "reading multiple dynamic fields issues at most one query" do
    Setting["key1"] = "value1"
    Setting["key2"] = "value2"
    Setting.clear_cache

    values = nil
    queries = capture_sql_queries do
      values = 3.times.map { [ Setting["key1"], Setting["key2"], Setting["missing_key"] ] }
    end

    assert_equal [ [ "value1", "value2", nil ] ] * 3, values
    assert_operator queries.grep(/FROM "settings"/).size, :<=, 1
  end

  test "dynamic field reads reflect updates after caching" do
    Setting["cached_key"] = "old"
    assert_equal "old", Setting["cached_key"]

    Setting["cached_key"] = "new"
    assert_equal "new", Setting["cached_key"]
  end

  test "setting nil value deletes dynamic field" do
    Setting["temp_key"] = "temp_value"
    assert_equal "temp_value", Setting["temp_key"]

    Setting["temp_key"] = nil
    assert_nil Setting["temp_key"]
  end

  test "can delete dynamic field" do
    Setting["delete_key"] = "delete_value"
    assert_equal "delete_value", Setting["delete_key"]

    value = Setting.delete("delete_key")
    assert_equal "delete_value", value
    assert_nil Setting["delete_key"]
  end

  test "key? returns true for existing dynamic field" do
    Setting["exists_key"] = "exists_value"
    assert Setting.key?("exists_key")
  end

  test "key? returns false for non-existing dynamic field" do
    assert_not Setting.key?("nonexistent_key")
  end

  test "dynamic_keys returns all dynamic field keys" do
    Setting["dynamic1"] = "value1"
    Setting["dynamic2"] = "value2"

    keys = Setting.dynamic_keys
    assert_includes keys, "dynamic1"
    assert_includes keys, "dynamic2"
  end

  test "declared fields take precedence over dynamic fields" do
    # Try to set a declared field using bracket notation
    Setting["openai_model"] = "custom-model"
    assert_equal "custom-model", Setting["openai_model"]
    assert_equal "custom-model", Setting.openai_model
  end

  test "cannot delete declared fields" do
    Setting.openai_model = "test-model"
    result = Setting.delete("openai_model")
    assert_nil result
    assert_equal "test-model", Setting.openai_model
  end

  test "brand_fetch_icon_url builds a logo URL with the requested fallback" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(40)

    assert_equal(
      "https://cdn.brandfetch.io/example.com/icon/fallback/404/w/40/h/40?c=test-client-id",
      Setting.brand_fetch_icon_url("example.com", fallback: "404")
    )
  end

  test "brand_fetch_icon_url supports namespaced routes and explicit dimensions" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    Setting.stubs(:brand_fetch_logo_size).returns(40)

    assert_equal(
      "https://cdn.brandfetch.io/crypto/BTC/icon/fallback/lettermark/w/80/h/80?c=test-client-id",
      Setting.brand_fetch_icon_url("BTC", namespace: "crypto", width: 80, height: 80)
    )
  end

  test "brand_fetch_icon_url returns nil without an identifier or client id" do
    Setting.stubs(:brand_fetch_client_id).returns("test-client-id")
    assert_nil Setting.brand_fetch_icon_url(nil)

    Setting.stubs(:brand_fetch_client_id).returns(nil)
    assert_nil Setting.brand_fetch_icon_url("example.com")
  end

  test "LLM_PROVIDER env wins over a stored llm_provider" do
    original = Setting.raw_llm_provider
    Setting.llm_provider = "anthropic"

    with_env_overrides("LLM_PROVIDER" => "openai") do
      assert_equal "openai", Setting.llm_provider
    end

    with_env_overrides("LLM_PROVIDER" => nil) do
      assert_equal "anthropic", Setting.llm_provider
    end
  ensure
    Setting.llm_provider = original
  end

  test "enabled_securities_providers falls back to twelve_data when nothing is configured" do
    with_env_overrides("SECURITIES_PROVIDERS" => nil, "SECURITIES_PROVIDER" => nil) do
      assert_equal [ "twelve_data" ], Setting.enabled_securities_providers
    end
  end

  test "enabled_securities_providers returns an empty list when explicitly cleared, not the legacy default" do
    original_providers = Setting.securities_providers
    original_provider = Setting.securities_provider

    Setting.securities_providers = ""
    Setting.securities_provider = ""

    assert_equal [], Setting.enabled_securities_providers
  ensure
    # Restore whatever was there before this test, not a hardcoded value —
    # and restore via assignment (not nil) either way, since
    # rails-settings-cached's cache layer doesn't reliably invalidate on
    # delete within a single test process, so a later test can still read
    # back the just-deleted blank override instead of falling through to
    # the field's default.
    Setting.securities_providers = original_providers.presence || ""
    Setting.securities_provider = original_provider.presence || "twelve_data"
  end

  test "reencrypt_secrets_from moves values from the old key to the current key" do
    old_secret_key_base = "old-secret-key-base-" + "a" * 64
    store_raw_setting("openai_access_token", old_setting_encryptor(old_secret_key_base).encrypt_and_sign("sk-old-key"))

    assert_not_equal "sk-old-key", Setting.openai_access_token

    results = Setting.reencrypt_secrets_from(old_secret_key_base, dry_run: false)

    assert_equal :reencrypted, results[:openai_access_token]
    assert_equal "sk-old-key", Setting.openai_access_token
    assert_not_equal "sk-old-key", Setting.find_by(var: "openai_access_token").value
  ensure
    Setting.openai_access_token = nil
  end

  test "reencrypt_secrets_from dry run reports without writing" do
    old_secret_key_base = "old-secret-key-base-" + "b" * 64
    ciphertext = old_setting_encryptor(old_secret_key_base).encrypt_and_sign("sk-old-key")
    store_raw_setting("openai_access_token", ciphertext)

    results = Setting.reencrypt_secrets_from(old_secret_key_base)

    assert_equal :would_reencrypt, results[:openai_access_token]
    assert_equal ciphertext, Setting.find_by(var: "openai_access_token").value
  ensure
    Setting.openai_access_token = nil
  end

  test "reencrypt_secrets_from leaves current and undecryptable values alone" do
    Setting.where(var: "twelve_data_api_key").delete_all
    Setting.openai_access_token = "sk-current"
    other_ciphertext = old_setting_encryptor("unrelated-" + "c" * 64).encrypt_and_sign("sk-lost")
    store_raw_setting("anthropic_access_token", other_ciphertext)

    results = Setting.reencrypt_secrets_from("old-secret-key-base-" + "d" * 64, dry_run: false)

    assert_equal :current, results[:openai_access_token]
    assert_equal :not_decryptable, results[:anthropic_access_token]
    assert_equal "sk-current", Setting.openai_access_token
    assert_equal other_ciphertext, Setting.find_by(var: "anthropic_access_token").value
    assert_equal :not_stored, results[:twelve_data_api_key]
  ensure
    Setting.openai_access_token = nil
    Setting.anthropic_access_token = nil
  end

  test "reencrypt_secrets_from rejects a blank old key" do
    assert_raises(ArgumentError) { Setting.reencrypt_secrets_from("") }
  end

  private

    def old_setting_encryptor(secret_key_base)
      key = ActiveSupport::KeyGenerator.new(secret_key_base).generate_key("setting_encryption", 32)
      ActiveSupport::MessageEncryptor.new(key)
    end

    def store_raw_setting(var, value)
      Setting.find_or_initialize_by(var: var).update!(value: value)
      Setting.clear_cache
    end
end
