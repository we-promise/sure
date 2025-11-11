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
end
