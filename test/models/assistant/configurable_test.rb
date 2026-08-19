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

  # The tool caller returns {error:, hint:} instead of raising; without this
  # rule the model sees those results as opaque data and never self-corrects.
  test "instructions teach the model to follow tool error hints" do
    config = Assistant.config_for(chats(:one))

    assert_includes config[:instructions],
      %(If a tool result contains an "error" and a "hint", follow the hint and retry once)
  end
end
