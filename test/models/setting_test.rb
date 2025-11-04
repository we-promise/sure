require "test_helper"

class SettingTest < ActiveSupport::TestCase
  setup do
    # Clear settings before each test
    Setting.openai_uri_base = nil
    Setting.openai_model = nil
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
end
