# frozen_string_literal: true

class MoveAiPromptsFromFamiliesToBuiltinAssistantConfigs < ActiveRecord::Migration[7.2]
  def up
    return unless column_exists?(:families, :preferred_ai_model)

    say_with_time "Backfill builtin_assistant_configs from families (model/endpoint only; prompts live in Langfuse)" do
      execute <<-SQL.squish
        INSERT INTO builtin_assistant_configs (id, family_id, preferred_ai_model, openai_uri_base, created_at, updated_at)
        SELECT gen_random_uuid(), id, preferred_ai_model, openai_uri_base, NOW(), NOW()
        FROM families
        WHERE preferred_ai_model IS NOT NULL AND preferred_ai_model != ''
           OR openai_uri_base IS NOT NULL AND openai_uri_base != ''
      SQL
    end

    remove_column :families, :preferred_ai_model, :string if column_exists?(:families, :preferred_ai_model)
    remove_column :families, :openai_uri_base, :string if column_exists?(:families, :openai_uri_base)
    remove_column :families, :custom_system_prompt, :text if column_exists?(:families, :custom_system_prompt)
    remove_column :families, :custom_intro_prompt, :text if column_exists?(:families, :custom_intro_prompt)
  end

  def down
    add_column :families, :preferred_ai_model, :string, limit: 128
    add_column :families, :openai_uri_base, :string, limit: 512

    say_with_time "Restore families columns from builtin_assistant_configs" do
      execute <<-SQL.squish
        UPDATE families f
        SET
          preferred_ai_model = c.preferred_ai_model,
          openai_uri_base = c.openai_uri_base
        FROM builtin_assistant_configs c
        WHERE c.family_id = f.id
      SQL
    end
  end
end
