require "test_helper"

class AssistantConfigurableTest < ActiveSupport::TestCase
  test "returns dashboard configuration by default" do
    chat = chats(:one)

    config = Assistant.config_for(chat)

    assert config.key?(:instructions_prompt), "config must include :instructions_prompt for Langfuse metadata"
    assert_not_empty config[:functions]
    assert_includes config[:instructions], "You help users understand their financial data"
    assert_nil config[:instructions_prompt], "Without Langfuse, instructions_prompt should be nil"
  end

  test "returns intro configuration without functions" do
    chat = chats(:intro)

    config = Assistant.config_for(chat)

    assert config.key?(:instructions_prompt), "config must include :instructions_prompt for Langfuse metadata"
    assert_equal [], config[:functions]
    assert_includes config[:instructions], "stage of life"
    assert_nil config[:instructions_prompt]
  end
end
