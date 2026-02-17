require "test_helper"

class Assistant::RoutingTest < ActiveSupport::TestCase
  test "for_chat routes to Builtin by default" do
    chat = chats(:two)
    assert_equal "builtin", chat.user.family.assistant_type
    assistant = Assistant.for_chat(chat)
    assert_instance_of Assistant::Builtin, assistant
  end

  test "for_chat routes to External when family prefers external" do
    chat = chats(:two)
    chat.user.family.update_column(:assistant_type, "external")
    assistant = Assistant.for_chat(chat)
    assert_instance_of Assistant::External, assistant
  end

  test "for_chat falls back to Builtin for unknown type" do
    chat = chats(:two)
    chat.user.family.update_column(:assistant_type, "unknown_type")
    assistant = Assistant.for_chat(chat)
    assert_instance_of Assistant::Builtin, assistant
  end

  test "available_types returns registered types" do
    types = Assistant.available_types
    assert_includes types, "builtin"
    assert_includes types, "external"
  end

  test "config_for delegates to Builtin" do
    chat = chats(:one)
    config = Assistant.config_for(chat)
    assert config[:instructions].present?
    assert config[:functions].present?
  end
end
