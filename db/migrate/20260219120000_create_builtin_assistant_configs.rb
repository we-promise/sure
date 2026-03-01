# frozen_string_literal: true

class CreateBuiltinAssistantConfigs < ActiveRecord::Migration[7.2]
  def change
    create_table :builtin_assistant_configs, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.text :custom_system_prompt
      t.text :custom_intro_prompt
      t.string :preferred_ai_model, limit: 128
      t.string :openai_uri_base, limit: 512

      t.timestamps
    end
  end
end
