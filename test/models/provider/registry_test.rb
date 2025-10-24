require "test_helper"

class Provider::RegistryTest < ActiveSupport::TestCase
  test "providers filters out nil values when provider is not configured" do
    # Ensure OpenAI is not configured
    Setting.stubs(:openai_access_token).returns(nil)
    ENV.stubs(:fetch).with("OPENAI_ACCESS_TOKEN", nil).returns(nil)

    registry = Provider::Registry.for_concept(:llm)

    # Should return empty array instead of [nil]
    assert_equal [], registry.providers
  end

  test "providers returns configured providers" do
    # Mock a configured OpenAI provider
    mock_provider = mock("openai_provider")
    Provider::Registry.stubs(:openai).returns(mock_provider)

    registry = Provider::Registry.for_concept(:llm)

    assert_equal [ mock_provider ], registry.providers
  end

  test "get_provider raises error when provider not found for concept" do
    registry = Provider::Registry.for_concept(:llm)

    error = assert_raises(Provider::Registry::Error) do
      registry.get_provider(:nonexistent)
    end

    assert_match(/Provider 'nonexistent' not found for concept: llm/, error.message)
  end

  test "get_provider returns nil when provider not configured" do
    # Ensure OpenAI is not configured
    Setting.stubs(:openai_access_token).returns(nil)
    ENV.stubs(:[]).with("OPENAI_ACCESS_TOKEN").returns(nil)

    registry = Provider::Registry.for_concept(:llm)

    # Should return nil when provider method exists but returns nil
    assert_nil registry.get_provider(:openai)
  end

  test "openai provider falls back to Setting when ENV is empty string" do
    # Simulate ENV being set to empty string (common in Docker/env files)
    ENV.stubs(:[]).with("OPENAI_ACCESS_TOKEN").returns("")
    ENV.stubs(:[]).with("OPENAI_URI_BASE").returns("")
    ENV.stubs(:[]).with("OPENAI_MODEL").returns("")

    Setting.stubs(:openai_access_token).returns("test-token-from-setting")
    Setting.stubs(:openai_uri_base).returns(nil)
    Setting.stubs(:openai_model).returns(nil)

    provider = Provider::Registry.get_provider(:openai)

    # Should successfully create provider using Setting value
    assert_not_nil provider
    assert_instance_of Provider::Openai, provider
  end
end
