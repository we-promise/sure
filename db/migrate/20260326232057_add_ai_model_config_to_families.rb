# frozen_string_literal: true

class AddAiModelConfigToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :preferred_ai_model, :string, limit: 128
    add_column :families, :openai_uri_base, :string, limit: 512
  end
end
