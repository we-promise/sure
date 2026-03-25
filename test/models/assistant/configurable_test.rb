require "test_helper"

class AssistantConfigurableTest < ActiveSupport::TestCase
  test "returns dashboard configuration by default" do
    chat = chats(:one)

    config = Assistant.config_for(chat)

    assert_not_empty config[:functions]
    assert_includes config[:instructions], "You help users understand their financial data"
    prompt = config[:instructions_prompt]
    assert_not_nil prompt, "instructions_prompt should fall back to the default prompt"
    assert_equal "default_instructions", prompt[:name]
    assert_equal config[:instructions], prompt[:content]
  end

  test "returns intro configuration without functions" do
    chat = chats(:intro)

    config = Assistant.config_for(chat)

    assert_equal [], config[:functions]
    assert_includes config[:instructions], "stage of life"
    prompt = config[:instructions_prompt]
    assert_not_nil prompt, "instructions_prompt should fall back to the intro prompt"
    assert_equal "intro_instructions", prompt[:name]
    assert_equal config[:instructions], prompt[:content]
  end
end
