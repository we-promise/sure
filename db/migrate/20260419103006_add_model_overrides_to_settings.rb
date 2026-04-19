class AddModelOverridesToSettings < ActiveRecord::Migration[7.2]
  def change
    add_column :settings, :openai_chat_model, :string
    add_column :settings, :openai_background_model, :string
  end
end
