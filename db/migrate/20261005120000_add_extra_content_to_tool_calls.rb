# frozen_string_literal: true

class AddExtraContentToToolCalls < ActiveRecord::Migration[8.1]
  def change
    add_column :tool_calls, :extra_content, :jsonb
  end
end
