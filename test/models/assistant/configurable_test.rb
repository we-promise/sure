require "test_helper"

class AssistantConfigurableTest < ActiveSupport::TestCase
  test "returns dashboard configuration by default" do
    chat = chats(:one)

    config = Assistant.config_for(chat)

    assert_not_empty config[:functions]
    assert_includes config[:instructions], "You help users understand their financial data"
  end

  test "returns intro configuration without functions" do
    chat = chats(:intro)

    config = Assistant.config_for(chat)

    assert_equal [], config[:functions]
    assert_includes config[:instructions], "stage of life"
  end
end
