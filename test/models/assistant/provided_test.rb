require "test_helper"

class Assistant::ProvidedTest < ActiveSupport::TestCase
  setup do
    @assistant = Assistant::Builtin.for_chat(chats(:two))
    @custom_openai = mock("custom_openai")
    @custom_openai.stubs(:supports_model?).returns(true)
    @anthropic = mock("anthropic")
    @anthropic.stubs(:supports_model?).with("claude-sonnet-4-6").returns(true)
    @anthropic.stubs(:supports_model?).with("gpt-4.1").returns(false)
    Provider::Registry.stubs(:openai).returns(@custom_openai)
    Provider::Registry.stubs(:anthropic).returns(@anthropic)
  end

  test "routes to the selected provider before a custom OpenAI endpoint that accepts any model" do
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_same @anthropic, @assistant.get_model_provider("claude-sonnet-4-6")
  end

  test "falls back to the other provider when the selected one doesn't support the model" do
    Setting.stubs(:llm_provider).returns("anthropic")

    assert_same @custom_openai, @assistant.get_model_provider("gpt-4.1")
  end

  test "builds each provider once when falling back" do
    Setting.stubs(:llm_provider).returns("anthropic")
    Provider::Registry.expects(:anthropic).once.returns(@anthropic)
    Provider::Registry.expects(:openai).once.returns(@custom_openai)

    assert_same @custom_openai, @assistant.get_model_provider("gpt-4.1")
  end

  test "keeps OpenAI first when it is selected" do
    Setting.stubs(:llm_provider).returns("openai")

    assert_same @custom_openai, @assistant.get_model_provider("claude-sonnet-4-6")
  end

  test "returns nil when no configured provider supports the model" do
    Setting.stubs(:llm_provider).returns("anthropic")
    Provider::Registry.stubs(:openai).returns(nil)

    assert_nil @assistant.get_model_provider("gpt-4.1")
  end
end
