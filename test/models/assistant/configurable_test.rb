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

  # Function names are plumbing; a reply that says "I ran get_bill_audit"
  # reads like a stack trace, not an assistant.
  test "instructions forbid naming internal tools in responses" do
    config = Assistant.config_for(chats(:one))

    assert_includes config[:instructions],
      "Never mention internal tool or function names in your responses"
  end
end
