# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261126120000_add_prompt_message_to_messages")

class AddPromptMessageToMessagesMigrationTest < ActiveSupport::TestCase
  # Starts from the table before the migration. DDL is transactional in
  # Postgres, so the change is rolled back with the rest of the test.
  setup do
    migration.down
    Message.reset_column_information
  end

  teardown do
    Message.reset_column_information
  end

  test "links each existing reply to the user message before it in its chat" do
    chat = chats(:two)
    chat.messages.delete_all
    first = insert_message(chat, "UserMessage", 3.minutes.ago)
    first_reply = insert_message(chat, "AssistantMessage", 2.minutes.ago)
    second = insert_message(chat, "UserMessage", 1.minute.ago)
    second_reply = insert_message(chat, "AssistantMessage", Time.current)

    migration.up
    Message.reset_column_information

    assert_equal first, prompt_of(first_reply)
    assert_equal second, prompt_of(second_reply)
    assert_nil prompt_of(first)
  end

  test "a reply loses its link, not its row, when its prompt is deleted" do
    migration.up
    Message.reset_column_information
    chat = chats(:two)
    chat.messages.delete_all
    prompt = insert_message(chat, "UserMessage", 1.minute.ago)
    reply = insert_message(chat, "AssistantMessage", Time.current)
    Message.where(id: reply).update_all(prompt_message_id: prompt)

    Message.where(id: prompt).delete_all

    assert_nil prompt_of(reply)
  end

  private
    def migration
      @migration ||= AddPromptMessageToMessages.new.tap { |m| m.verbose = false }
    end

    def insert_message(chat, type, created_at)
      Message.insert!({ chat_id: chat.id, type: type, content: "text", ai_model: "gpt-4.1", status: "complete",
                        created_at: created_at, updated_at: created_at }, returning: :id).rows.first.first
    end

    def prompt_of(id)
      Message.connection.select_value(Message.sanitize_sql([ "SELECT prompt_message_id FROM messages WHERE id = ?", id ]))
    end
end
