# frozen_string_literal: true

class RemovePromptColumnsFromBuiltinAssistantConfigs < ActiveRecord::Migration[7.2]
  def up
    remove_column :builtin_assistant_configs, :custom_system_prompt, :text if column_exists?(:builtin_assistant_configs, :custom_system_prompt)
    remove_column :builtin_assistant_configs, :custom_intro_prompt, :text if column_exists?(:builtin_assistant_configs, :custom_intro_prompt)
  end

  def down
    add_column :builtin_assistant_configs, :custom_system_prompt, :text unless column_exists?(:builtin_assistant_configs, :custom_system_prompt)
    add_column :builtin_assistant_configs, :custom_intro_prompt, :text unless column_exists?(:builtin_assistant_configs, :custom_intro_prompt)
  end
end
