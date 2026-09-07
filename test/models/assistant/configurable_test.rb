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

  test "instructions start with the byte-stable static block and end with session context" do
    chat = chats(:one)

    instructions = Assistant.config_for(chat)[:instructions]

    assert instructions.start_with?(Assistant::Configurable::STATIC_INSTRUCTIONS)
    assert_operator instructions.index("## Session context"), :>, instructions.index("### Rules about financial advice")
    assert_includes instructions, "Today's date: #{Date.current}"
  end

  test "session context lists accounts and categories for a typical family" do
    chat = chats(:one)
    family = chat.user.family

    # The roster only itemizes when the model's context window is comfortable
    Setting.stubs(:llm_context_window).returns(128_000)

    instructions = Assistant.config_for(chat)[:instructions]

    visible_account = chat.user.accessible_accounts.visible.first

    assert_includes instructions, "### Accounts"
    assert_includes instructions, visible_account.name
    assert_includes instructions, "### Categories"
    assert_includes instructions, family.categories.first.name
    assert_includes instructions, "Uncategorized"
  end

  test "session context collapses to counts for large account rosters" do
    chat = chats(:one)
    user = chat.user

    Setting.stubs(:llm_context_window).returns(128_000)

    26.times do |i|
      user.family.accounts.create!(
        name: "Roster Account #{i}",
        balance: 100,
        currency: "USD",
        accountable: Depository.new
      )
    end

    instructions = Assistant.config_for(chat)[:instructions]

    assert_match(/\d+ accounts:/, instructions)
    assert_not_includes instructions, "Roster Account 1:"
  end

  test "session context collapses to counts on small context windows" do
    chat = chats(:one)

    Setting.stubs(:llm_context_window).returns(2048)

    instructions = Assistant.config_for(chat)[:instructions]

    assert_match(/\d+ accounts:/, instructions)
    assert_match(/\d+ categories\./, instructions)
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
