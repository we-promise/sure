class AddAssistantTypeToChats < ActiveRecord::Migration[8.0]
  def change
    add_column :chats, :assistant_type, :string, default: "builtin", null: false
  end
end
