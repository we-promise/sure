# frozen_string_literal: true

class AddRoundToToolCalls < ActiveRecord::Migration[8.1]
  def change
    add_column :tool_calls, :round, :integer
  end
end
