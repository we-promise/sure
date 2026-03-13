# frozen_string_literal: true

class MoveAiPromptsFromFamiliesToBuiltinAssistantConfigs < ActiveRecord::Migration[7.2]
  def up
    return unless column_exists?(:families, :custom_system_prompt)

    say_with_time "Backfill builtin_assistant_configs from families" do
      execute <<-SQL.squish
        INSERT INTO builtin_assistant_configs (id, family_id, custom_system_prompt, custom_intro_prompt, preferred_ai_model, openai_uri_base, created_at, updated_at)
        SELECT gen_random_uuid(), id, custom_system_prompt, custom_intro_prompt, preferred_ai_model, openai_uri_base, NOW(), NOW()
        FROM families
        WHERE custom_system_prompt IS NOT NULL AND custom_system_prompt != ''
           OR custom_intro_prompt IS NOT NULL AND custom_intro_prompt != ''
           OR preferred_ai_model IS NOT NULL AND preferred_ai_model != ''
           OR openai_uri_base IS NOT NULL AND openai_uri_base != ''
      SQL
    end

    remove_column :families, :custom_system_prompt, :text
    remove_column :families, :custom_intro_prompt, :text
    remove_column :families, :preferred_ai_model, :string
    remove_column :families, :openai_uri_base, :string
  end

  def down
    add_column :families, :custom_system_prompt, :text
    add_column :families, :custom_intro_prompt, :text
    add_column :families, :preferred_ai_model, :string, limit: 128
    add_column :families, :openai_uri_base, :string, limit: 512

    say_with_time "Restore families columns from builtin_assistant_configs" do
      execute <<-SQL.squish
        UPDATE families f
        SET
          custom_system_prompt = c.custom_system_prompt,
          custom_intro_prompt = c.custom_intro_prompt,
          preferred_ai_model = c.preferred_ai_model,
          openai_uri_base = c.openai_uri_base
        FROM builtin_assistant_configs c
        WHERE c.family_id = f.id
      SQL
    end
  end
end
