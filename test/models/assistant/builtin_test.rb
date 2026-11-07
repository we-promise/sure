require "test_helper"

class Assistant::BuiltinTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:two)
    @family = @chat.user.family
    @message = @chat.messages.create!(type: "UserMessage", content: "Continue our conversation", ai_model: Provider::Openai::DEFAULT_MODEL)
    @assistant = Assistant::Builtin.new(@chat)
    @responder = mock("responder")
    @responder.stubs(:on)
    Assistant::Responder.stubs(:new).returns(@responder)
  end

  test "family key and provider changes cannot reuse an old account response ID" do
    configuration = @family.create_ai_configuration!(provider: "openai", api_key: "test-first-key")
    Current.stubs(:user).returns(users(:empty))

    [ [ "openai", "test-first-key" ], [ "openai", "test-rotated-key" ], [ "anthropic", "test-anthropic-key" ] ].each do |provider, key|
      configuration.update!(provider: provider, api_key: key, model: Family::AiConfiguration.default_model(provider))
      @message.update!(ai_model: configuration.model)
      # Simulate an older in-flight request writing its response ID after rotation.
      @chat.update!(latest_assistant_response_id: "response-from-old-account")
      @responder.expects(:respond).with(previous_response_id: nil)
      @chat.expects(:add_error).never

      @assistant.respond_to(@message)
    end
  end

  test "retrying an old model after a family provider switch fails closed" do
    @family.create_ai_configuration!(provider: "anthropic", api_key: "test-anthropic-key")
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never
    Assistant::Responder.expects(:new).never
    @chat.expects(:add_error).with do |error|
      error.message.include?("No LLM provider configured that supports model '#{@message.ai_model}'")
    end

    @assistant.respond_to(@message)

    assert_equal Provider::Anthropic::DEFAULT_MODEL, Chat.default_model(family: @chat.user.family)
  end

  test "legacy installation chats keep their native cross-turn response ID" do
    @chat.update!(latest_assistant_response_id: "legacy-response")
    @assistant.stubs(:get_model_provider).returns(stub)
    @responder.expects(:respond).with(previous_response_id: "legacy-response")
    @chat.expects(:add_error).never

    @assistant.respond_to(@message)
  end
end
