class AddAiPromptOverridesToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :ai_prompt_overrides, :jsonb, default: {}, null: false
  end
end
