# Each assistant reply records the user message it answers, so Retry asks
# again for that prompt instead of guessing it from timestamps. Existing
# replies get the user message before them in their chat, the same guess
# Retry made until now.
class AddPromptMessageToMessages < ActiveRecord::Migration[8.1]
  def up
    add_reference :messages, :prompt_message, type: :uuid, index: true,
                  foreign_key: { to_table: :messages, on_delete: :nullify }

    execute <<~SQL
      UPDATE messages AS reply
      SET prompt_message_id = (
        SELECT prompt.id
        FROM messages AS prompt
        WHERE prompt.chat_id = reply.chat_id
          AND prompt.type = 'UserMessage'
          AND prompt.created_at <= reply.created_at
        ORDER BY prompt.created_at DESC
        LIMIT 1
      )
      WHERE reply.type = 'AssistantMessage'
    SQL
  end

  def down
    remove_reference :messages, :prompt_message, index: true, foreign_key: { to_table: :messages }
  end
end
