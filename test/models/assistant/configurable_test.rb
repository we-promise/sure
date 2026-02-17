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

  test "interpolates currency and date format into instructions" do
    chat = chats(:one)

    config = Assistant.config_for(chat)
    currency = Money::Currency.new(chat.user.family.currency)

    assert_includes config[:instructions], currency.symbol
    assert_includes config[:instructions], currency.iso_code
    assert_includes config[:instructions], Date.current.to_s
  end

  test "falls back gracefully when YAML config is missing" do
    original_instructions = Rails.configuration.x.assistant.instructions
    Rails.configuration.x.assistant.instructions = {}

    chat = chats(:one)
    config = Assistant.config_for(chat)

    assert config[:instructions].present?
    assert_includes config[:instructions], "Sure"
  ensure
    Rails.configuration.x.assistant.instructions = original_instructions
  end
end
