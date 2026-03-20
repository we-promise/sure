# frozen_string_literal: true

class AddAiPromptOverridesToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :preferred_ai_model, :string
  end
end
